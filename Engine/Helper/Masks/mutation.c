#include "masks.h"

static gboolean change(dt_develop_t *dev, JsonObject *mutation, char **err)
{
  double id;
  if(!np_mask_number(mutation, "id", 1, INT32_MAX, &id, err) || floor(id) != id)
    return np_mask_fail(err, "mask identity must be a positive 32-bit integer");
  const char *action = json_object_get_string_member(mutation, "action");
  dt_masks_form_t *old = dt_masks_get_from_id(dev, id);
  if(!action) return np_mask_fail(err, "mask mutation action is unavailable");
  if(!strcmp(action, "delete"))
  {
    if(!old) return np_mask_fail(err, "deleted mask does not exist");
    dev->forms = g_list_remove(dev->forms, old);
    dev->allforms = g_list_remove(dev->allforms, old);
    dt_masks_free_form(old);
    return TRUE;
  }
  const gboolean create = !strcmp(action, "create");
  if(!create && strcmp(action, "update")) return np_mask_fail(err, "unknown mask mutation action");
  if(create ? old != NULL : old == NULL) return np_mask_fail(err, "mask identity is duplicated or unavailable");
  const char *name = json_object_has_member(mutation, "name")
    ? json_object_get_string_member(mutation, "name") : old ? old->name : NULL;
  if(!name || !g_utf8_validate(name, -1, NULL) || strlen(name) >= 128)
    return np_mask_fail(err, "mask name must fit in 127 UTF-8 bytes");
  JsonObject *geometry = np_mask_object(mutation, "geometry");
  if(create && !geometry) return np_mask_fail(err, "new mask requires supported geometry");
  if(!geometry)
  {
    g_strlcpy(old->name, name, sizeof(old->name));
    return TRUE;
  }
  if(old && (old->version != dt_masks_version() || (old->type != DT_MASKS_CIRCLE
      && old->type != DT_MASKS_ELLIPSE && old->type != DT_MASKS_GRADIENT && old->type != DT_MASKS_GROUP)))
    return np_mask_fail(err, "unsupported mask geometry remains read-only");
  dt_masks_form_t *form = np_mask_geometry(geometry, id, err);
  if(!form) return FALSE;
  if(old && form->type != old->type)
  { dt_masks_free_form(form); return np_mask_fail(err, "mask update cannot change its shape type"); }
  g_strlcpy(form->name, name, sizeof(form->name));
  if(old)
  {
    memcpy(form->source, old->source, sizeof(form->source));
    GList *link = g_list_find(dev->forms, old);
    link->data = form;
    dev->allforms = g_list_remove(dev->allforms, old);
    dt_masks_free_form(old);
  }
  else dev->forms = g_list_append(dev->forms, form);
  return TRUE;
}

static gboolean group_valid(dt_develop_t *dev, const dt_masks_form_t *form,
                            GHashTable *visiting, GHashTable *visited, guint depth, char **err)
{
  if(!(form->type & DT_MASKS_GROUP)) return TRUE;
  gpointer key = GINT_TO_POINTER(form->formid);
  if(g_hash_table_contains(visiting, key)) return np_mask_fail(err, "mask group references form a cycle");
  if(g_hash_table_contains(visited, key)) return TRUE;
  if(depth > 128) return np_mask_fail(err, "mask group nesting exceeds 128 levels");
  g_hash_table_add(visiting, key);
  for(GList *it = form->points; it; it = it->next)
  {
    const dt_masks_point_group_t *point = it->data;
    const dt_masks_form_t *child = dt_masks_get_from_id(dev, point->formid);
    if(!child) return np_mask_fail(err, "mask group references an unavailable mask");
    if(!group_valid(dev, child, visiting, visited, depth + 1, err)) return FALSE;
  }
  g_hash_table_remove(visiting, key);
  g_hash_table_add(visited, key);
  return TRUE;
}

static gboolean references_valid(dt_develop_t *dev, char **err)
{
  GHashTable *visiting = g_hash_table_new(g_direct_hash, g_direct_equal);
  GHashTable *visited = g_hash_table_new(g_direct_hash, g_direct_equal);
  GHashTable *identities = g_hash_table_new(g_direct_hash, g_direct_equal);
  gboolean valid = TRUE;
  for(GList *it = dev->forms; valid && it; it = it->next)
  {
    const dt_masks_form_t *form = it->data;
    gpointer key = GINT_TO_POINTER(form->formid);
    if(form->formid <= 0 || g_hash_table_contains(identities, key))
      valid = np_mask_fail(err, "accepted mask identities are invalid");
    g_hash_table_add(identities, key);
    if(valid) valid = group_valid(dev, form, visiting, visited, 0, err);
  }
  for(GList *it = dev->iop; valid && it; it = it->next)
  {
    const dt_iop_module_t *module = it->data;
    const dt_develop_blend_params_t *blend = module->blend_params;
    if(blend && blend->mask_id && !dt_masks_get_from_id(dev, blend->mask_id))
      valid = np_mask_fail(err, "module blend references an unavailable mask");
    if(blend && (blend->mask_mode & DEVELOP_MASK_MASK) && !blend->mask_id)
      valid = np_mask_fail(err, "drawn blending requires an assigned mask");
  }
  g_hash_table_unref(visiting);
  g_hash_table_unref(visited);
  g_hash_table_unref(identities);
  return valid;
}

gboolean np_masks_apply(dt_develop_t *dev, JsonObject *edit, char **err)
{
  JsonNode *mutations_node = json_object_get_member(edit, "mutations");
  JsonNode *blends_node = json_object_get_member(edit, "blends");
  if(!mutations_node || !JSON_NODE_HOLDS_ARRAY(mutations_node)
      || !blends_node || !JSON_NODE_HOLDS_ARRAY(blends_node))
    return np_mask_fail(err, "mask edit requires mutation and blend arrays");
  JsonArray *mutations = json_node_get_array(mutations_node);
  JsonArray *blends = json_node_get_array(blends_node);
  if(json_array_get_length(mutations) > 1024 || json_array_get_length(blends) > 256)
    return np_mask_fail(err, "mask edit exceeds the supported transaction size");
  for(guint index = 0; index < json_array_get_length(mutations); index++)
  {
    JsonNode *node = json_array_get_element(mutations, index);
    if(!JSON_NODE_HOLDS_OBJECT(node) || !change(dev, json_node_get_object(node), err)) return FALSE;
  }
  for(guint index = 0; index < json_array_get_length(blends); index++)
  {
    JsonNode *node = json_array_get_element(blends, index);
    if(!JSON_NODE_HOLDS_OBJECT(node) || !np_blend_patch(dev, json_node_get_object(node), err)) return FALSE;
  }
  if(!references_valid(dev, err)) return FALSE;
  for(guint index = 0; index < json_array_get_length(blends); index++)
  {
    JsonObject *entry = json_array_get_object_element(blends, index);
    dt_iop_module_t *module = dt_iop_get_module_by_op_priority(dev->iop,
      json_object_get_string_member(entry, "operation"), json_object_get_int_member(entry, "instance"));
    dt_dev_add_masks_history_item_ext(dev, module, module->enabled, TRUE);
  }
  dt_dev_add_masks_history_item_ext(dev, NULL, FALSE, TRUE);
  return TRUE;
}
