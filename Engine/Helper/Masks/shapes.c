#include "masks.h"

static gboolean circle(dt_masks_form_t *form, JsonObject *value, char **err)
{
  dt_masks_point_circle_t *point = calloc(1, sizeof(*point));
  form->points = g_list_append(form->points, point);
  double radius, feather;
  if(!np_mask_point(value, "center", point->center, err)
      || !np_mask_number(value, "radius", 0.000001, 1, &radius, err)
      || !np_mask_number(value, "feather", 0, 1, &feather, err)) return FALSE;
  point->radius = radius;
  point->border = feather;
  return TRUE;
}

static gboolean ellipse(dt_masks_form_t *form, JsonObject *value, char **err)
{
  dt_masks_point_ellipse_t *point = calloc(1, sizeof(*point));
  form->points = g_list_append(form->points, point);
  double rotation, feather, mode;
  if(!np_mask_point(value, "center", point->center, err)
      || !np_mask_point(value, "radius", point->radius, err)
      || point->radius[0] < 0.000001 || point->radius[1] < 0.000001
      || !np_mask_number(value, "rotation", -360, 360, &rotation, err)
      || !np_mask_number(value, "featherMode", 0, 1, &mode, err) || floor(mode) != mode
      || !np_mask_number(value, "feather", 0, mode == 0 ? 1 : 10, &feather, err))
    return np_mask_fail(err, "ellipse geometry is invalid");
  point->rotation = rotation;
  point->border = feather;
  point->flags = mode;
  return TRUE;
}

static gboolean gradient(dt_masks_form_t *form, JsonObject *value, char **err)
{
  dt_masks_point_gradient_t *point = calloc(1, sizeof(*point));
  form->points = g_list_append(form->points, point);
  double rotation, compression, steepness, curvature, transition;
  if(!np_mask_point(value, "anchor", point->anchor, err)
      || !np_mask_number(value, "rotation", -360, 360, &rotation, err)
      || !np_mask_number(value, "compression", 0.001, 1, &compression, err)
      || !np_mask_number(value, "steepness", 0, 1, &steepness, err)
      || !np_mask_number(value, "curvature", -2, 2, &curvature, err)
      || !np_mask_number(value, "transition", 1, 2, &transition, err) || floor(transition) != transition)
    return FALSE;
  point->rotation = rotation;
  point->compression = compression;
  point->steepness = steepness;
  point->curvature = curvature;
  point->state = transition;
  return TRUE;
}

static gboolean group(dt_masks_form_t *form, JsonArray *members, char **err)
{
  if(!members || json_array_get_length(members) > 1024)
    return np_mask_fail(err, "mask group must contain at most 1024 ordered members");
  for(guint index = 0; index < json_array_get_length(members); index++)
  {
    JsonNode *node = json_array_get_element(members, index);
    if(!JSON_NODE_HOLDS_OBJECT(node)) return np_mask_fail(err, "mask group member is invalid");
    JsonObject *member = json_node_get_object(node);
    double id, opacity, operation, preserved;
    if(!np_mask_number(member, "maskID", 1, INT32_MAX, &id, err) || floor(id) != id
        || !np_mask_number(member, "opacity", 0, 1, &opacity, err)
        || !np_mask_number(member, "operation", 8, 128, &operation, err)
        || (operation != 8 && operation != 16 && operation != 32 && operation != 64 && operation != 128)
        || !np_mask_number(member, "preservedFlags", 0, INT32_MAX, &preserved, err)
        || floor(preserved) != preserved || ((int)preserved & 255))
      return np_mask_fail(err, "mask group member fields are invalid");
    dt_masks_point_group_t *point = calloc(1, sizeof(*point));
    point->formid = id;
    point->parentid = form->formid;
    point->opacity = opacity;
    point->state = (int)operation | (int)preserved;
    if(json_object_get_boolean_member(member, "inverted")) point->state |= DT_MASKS_STATE_INVERSE;
    if(json_object_get_boolean_member(member, "enabled")) point->state |= DT_MASKS_STATE_USE;
    if(json_object_get_boolean_member(member, "visible")) point->state |= DT_MASKS_STATE_SHOW;
    form->points = g_list_append(form->points, point);
  }
  return TRUE;
}

dt_masks_form_t *np_mask_geometry(JsonObject *geometry, dt_mask_id_t id, char **err)
{
  const char *kind = geometry && json_object_has_member(geometry, "kind")
    ? json_object_get_string_member(geometry, "kind") : NULL;
  dt_masks_type_t type = !kind ? DT_MASKS_NONE : !strcmp(kind, "circle") ? DT_MASKS_CIRCLE
    : !strcmp(kind, "ellipse") ? DT_MASKS_ELLIPSE : !strcmp(kind, "gradient") ? DT_MASKS_GRADIENT
    : !strcmp(kind, "group") ? DT_MASKS_GROUP : DT_MASKS_NONE;
  if(type == DT_MASKS_NONE) { np_mask_fail(err, "unsupported mask geometry"); return NULL; }
  dt_masks_form_t *form = dt_masks_create(type);
  if(!form) { np_mask_fail(err, "mask allocation failed"); return NULL; }
  form->formid = id;
  JsonObject *value = np_mask_object(geometry, "value");
  gboolean valid = FALSE;
  if(type == DT_MASKS_CIRCLE) valid = circle(form, value, err);
  else if(type == DT_MASKS_ELLIPSE) valid = ellipse(form, value, err);
  else if(type == DT_MASKS_GRADIENT) valid = gradient(form, value, err);
  else
  {
    JsonNode *node = json_object_get_member(geometry, "value");
    valid = group(form, node && JSON_NODE_HOLDS_ARRAY(node) ? json_node_get_array(node) : NULL, err);
  }
  if(!valid) { dt_masks_free_form(form); return NULL; }
  return form;
}
