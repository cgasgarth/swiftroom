#pragma once
#include "native_photo.h"
#include "develop/blend.h"
#include "develop/masks.h"
#include <math.h>

gboolean np_masks_apply(dt_develop_t *dev, JsonObject *edit, char **err);
void np_masks_state(JsonBuilder *builder, dt_develop_t *dev);
gboolean np_mask_form_editable(const dt_masks_form_t *form);
dt_masks_form_t *np_mask_geometry(JsonObject *geometry, dt_mask_id_t id, char **err);
gboolean np_blend_patch(dt_develop_t *dev, JsonObject *entry, char **err);

static inline gboolean np_mask_fail(char **err, const char *message)
{
  if(!*err) *err = g_strdup(message);
  return FALSE;
}

static inline gboolean np_mask_number(JsonObject *object, const char *key,
                                     double lower, double upper, double *value, char **err)
{
  JsonNode *node = object ? json_object_get_member(object, key) : NULL;
  if(!node || !JSON_NODE_HOLDS_VALUE(node)
      || (json_node_get_value_type(node) != G_TYPE_DOUBLE && json_node_get_value_type(node) != G_TYPE_INT64))
    return np_mask_fail(err, "mask geometry requires numeric fields");
  *value = json_node_get_double(node);
  if(!isfinite(*value) || *value < lower || *value > upper)
    return np_mask_fail(err, "mask geometry is outside its finite bounds");
  return TRUE;
}

static inline JsonObject *np_mask_object(JsonObject *object, const char *key)
{
  JsonNode *node = object ? json_object_get_member(object, key) : NULL;
  return node && JSON_NODE_HOLDS_OBJECT(node) ? json_node_get_object(node) : NULL;
}

static inline gboolean np_mask_point(JsonObject *object, const char *key, float *point, char **err)
{
  JsonObject *value = np_mask_object(object, key);
  double x, y;
  if(!np_mask_number(value, "x", 0, 1, &x, err) || !np_mask_number(value, "y", 0, 1, &y, err))
    return FALSE;
  point[0] = x;
  point[1] = y;
  return TRUE;
}

static inline void np_mask_int(JsonBuilder *builder, const char *key, gint64 value)
{
  json_builder_set_member_name(builder, key);
  json_builder_add_int_value(builder, value);
}

static inline void np_mask_float(JsonBuilder *builder, const char *key, double value)
{
  json_builder_set_member_name(builder, key);
  json_builder_add_double_value(builder, value);
}

static inline void np_mask_text(JsonBuilder *builder, const char *key, const char *value)
{
  json_builder_set_member_name(builder, key);
  json_builder_add_string_value(builder, value);
}

static inline void np_mask_bool(JsonBuilder *builder, const char *key, gboolean value)
{
  json_builder_set_member_name(builder, key);
  json_builder_add_boolean_value(builder, value);
}

static inline void np_mask_write_point(JsonBuilder *builder, const char *key, const float *point)
{
  json_builder_set_member_name(builder, key);
  json_builder_begin_object(builder);
  np_mask_float(builder, "x", point[0]);
  np_mask_float(builder, "y", point[1]);
  json_builder_end_object(builder);
}
