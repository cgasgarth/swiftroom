#include "masks.h"
#include <dlfcn.h>

gboolean np_bezier_render_mode(dt_develop_t *dev, char **err)
{
  for(GList *it = dev->forms; it; it = it->next)
  {
    const dt_masks_form_t *form = it->data;
    if(!(form->type & DT_MASKS_BRUSH)) continue;
    void (*set_threads)(int) = (void (*)(int))dlsym(RTLD_DEFAULT, "omp_set_num_threads");
    if(!set_threads) return np_mask_fail(err, "repeatable brush processing requires the pinned OpenMP runtime");
    darktable.num_openmp_threads = 1;
    set_threads(1);
    break;
  }
  return TRUE;
}

static gboolean point_bounds(JsonObject *object, const char *key, float *point,
                             double lower, double upper, char **err)
{
  JsonObject *value = np_mask_object(object, key);
  double horizontal, vertical;
  if(!np_mask_number(value, "x", lower, upper, &horizontal, err)
      || !np_mask_number(value, "y", lower, upper, &vertical, err)) return FALSE;
  point[0] = horizontal;
  point[1] = vertical;
  return TRUE;
}

static gboolean curve(JsonObject *value, float *corner, float *control_in, float *control_out,
                      float *feather, dt_masks_points_states_t *state, char **err)
{
  double mode;
  if(!point_bounds(value, "corner", corner, 0, 1, err)
      || !point_bounds(value, "controlIn", control_in, -2, 3, err)
      || !point_bounds(value, "controlOut", control_out, -2, 3, err)
      || !point_bounds(value, "feather", feather, 0, 1, err)
      || !np_mask_number(value, "state", 1, 2, &mode, err) || floor(mode) != mode)
    return np_mask_fail(err, "Bezier control fields are invalid");
  *state = mode;
  return TRUE;
}

gboolean np_bezier_geometry(dt_masks_form_t *form, JsonArray *points, char **err)
{
  const gboolean brush = form->type == DT_MASKS_BRUSH;
  if(!points || json_array_get_length(points) < (brush ? 2u : 3u)
      || json_array_get_length(points) > 1024)
    return np_mask_fail(err, "path requires 3...1024 points; brush requires 2...1024 points");
  for(guint index = 0; index < json_array_get_length(points); index++)
  {
    JsonNode *node = json_array_get_element(points, index);
    if(!JSON_NODE_HOLDS_OBJECT(node)) return np_mask_fail(err, "Bezier point requires a typed object");
    JsonObject *value = json_node_get_object(node);
    if(brush)
    {
      dt_masks_point_brush_t *point = calloc(1, sizeof(*point));
      form->points = g_list_append(form->points, point);
      double density, hardness;
      if(!curve(np_mask_object(value, "curve"), point->corner, point->ctrl1, point->ctrl2,
                point->border, &point->state, err)
          || !np_mask_number(value, "density", 0, 1, &density, err)
          || !np_mask_number(value, "hardness", 0, 1, &hardness, err)) return FALSE;
      point->density = density;
      point->hardness = hardness;
    }
    else
    {
      dt_masks_point_path_t *point = calloc(1, sizeof(*point));
      form->points = g_list_append(form->points, point);
      if(!curve(value, point->corner, point->ctrl1, point->ctrl2, point->border, &point->state, err)) return FALSE;
    }
  }
  return TRUE;
}

gboolean np_bezier_supported(const dt_masks_form_t *form)
{
  const guint count = g_list_length(form->points);
  if(count < (form->type == DT_MASKS_BRUSH ? 2u : 3u) || count > 1024) return FALSE;
  for(GList *it = form->points; it; it = it->next)
  {
    const dt_masks_points_states_t state = form->type == DT_MASKS_BRUSH
      ? ((dt_masks_point_brush_t *)it->data)->state : ((dt_masks_point_path_t *)it->data)->state;
    if(state != DT_MASKS_POINT_STATE_NORMAL && state != DT_MASKS_POINT_STATE_USER) return FALSE;
  }
  return TRUE;
}

static void write_curve(JsonBuilder *builder, const float *corner, const float *control_in,
                        const float *control_out, const float *feather, dt_masks_points_states_t state)
{
  np_mask_write_point(builder, "corner", corner);
  np_mask_write_point(builder, "controlIn", control_in);
  np_mask_write_point(builder, "controlOut", control_out);
  np_mask_write_point(builder, "feather", feather);
  np_mask_int(builder, "state", state);
}

void np_bezier_write(JsonBuilder *builder, const dt_masks_form_t *form)
{
  json_builder_begin_array(builder);
  for(GList *it = form->points; it; it = it->next)
  {
    json_builder_begin_object(builder);
    if(form->type == DT_MASKS_BRUSH)
    {
      const dt_masks_point_brush_t *point = it->data;
      json_builder_set_member_name(builder, "curve");
      json_builder_begin_object(builder);
      write_curve(builder, point->corner, point->ctrl1, point->ctrl2, point->border, point->state);
      json_builder_end_object(builder);
      np_mask_float(builder, "density", point->density);
      np_mask_float(builder, "hardness", point->hardness);
    }
    else
    {
      const dt_masks_point_path_t *point = it->data;
      write_curve(builder, point->corner, point->ctrl1, point->ctrl2, point->border, point->state);
    }
    json_builder_end_object(builder);
  }
  json_builder_end_array(builder);
}
