#include "masks.h"

gboolean np_mask_form_editable(const dt_masks_form_t *form)
{
  if(form->version != dt_masks_version()) return FALSE;
  if(form->type == DT_MASKS_PATH || form->type == DT_MASKS_BRUSH) return np_bezier_supported(form);
  if(form->type == DT_MASKS_GROUP)
  {
    for(GList *it = form->points; it; it = it->next)
    {
      const dt_masks_point_group_t *point = it->data;
      const int operation = point->state & DT_MASKS_STATE_OP;
      if(operation != 8 && operation != 16 && operation != 32 && operation != 64 && operation != 128)
        return FALSE;
    }
    return TRUE;
  }
  if(g_list_length(form->points) != 1) return FALSE;
  if(form->type == DT_MASKS_ELLIPSE)
  {
    const dt_masks_point_ellipse_t *point = form->points->data;
    return point->flags == DT_MASKS_ELLIPSE_EQUIDISTANT || point->flags == DT_MASKS_ELLIPSE_PROPORTIONAL;
  }
  if(form->type == DT_MASKS_GRADIENT)
  {
    const dt_masks_point_gradient_t *point = form->points->data;
    return point->state == DT_MASKS_GRADIENT_STATE_LINEAR || point->state == DT_MASKS_GRADIENT_STATE_SIGMOIDAL;
  }
  return form->type == DT_MASKS_CIRCLE;
}

static void geometry(JsonBuilder *builder, const dt_masks_form_t *form)
{
  json_builder_set_member_name(builder, "geometry");
  if(!np_mask_form_editable(form)) { json_builder_add_null_value(builder); return; }
  json_builder_begin_object(builder);
  const char *kind = form->type == DT_MASKS_CIRCLE ? "circle" : form->type == DT_MASKS_ELLIPSE
    ? "ellipse" : form->type == DT_MASKS_GRADIENT ? "gradient" : form->type == DT_MASKS_PATH
    ? "path" : form->type == DT_MASKS_BRUSH ? "brush" : "group";
  np_mask_text(builder, "kind", kind);
  json_builder_set_member_name(builder, "value");
  if(form->type == DT_MASKS_PATH || form->type == DT_MASKS_BRUSH) np_bezier_write(builder, form);
  else if(form->type == DT_MASKS_GROUP)
  {
    json_builder_begin_array(builder);
    for(GList *it = form->points; it; it = it->next)
    {
      const dt_masks_point_group_t *point = it->data;
      json_builder_begin_object(builder);
      np_mask_int(builder, "maskID", point->formid);
      np_mask_float(builder, "opacity", point->opacity);
      np_mask_int(builder, "operation", point->state & DT_MASKS_STATE_OP);
      np_mask_bool(builder, "inverted", point->state & DT_MASKS_STATE_INVERSE);
      np_mask_bool(builder, "enabled", point->state & DT_MASKS_STATE_USE);
      np_mask_bool(builder, "visible", point->state & DT_MASKS_STATE_SHOW);
      np_mask_int(builder, "preservedFlags", (uint32_t)point->state & ~255u);
      json_builder_end_object(builder);
    }
    json_builder_end_array(builder);
  }
  else
  {
    json_builder_begin_object(builder);
    if(form->type == DT_MASKS_CIRCLE)
    {
      const dt_masks_point_circle_t *point = form->points->data;
      np_mask_write_point(builder, "center", point->center);
      np_mask_float(builder, "radius", point->radius);
      np_mask_float(builder, "feather", point->border);
    }
    else if(form->type == DT_MASKS_ELLIPSE)
    {
      const dt_masks_point_ellipse_t *point = form->points->data;
      np_mask_write_point(builder, "center", point->center);
      np_mask_write_point(builder, "radius", point->radius);
      np_mask_float(builder, "rotation", point->rotation);
      np_mask_float(builder, "feather", point->border);
      np_mask_int(builder, "featherMode", point->flags);
    }
    else
    {
      const dt_masks_point_gradient_t *point = form->points->data;
      np_mask_write_point(builder, "anchor", point->anchor);
      np_mask_float(builder, "rotation", point->rotation);
      np_mask_float(builder, "compression", point->compression);
      np_mask_float(builder, "steepness", point->steepness);
      np_mask_float(builder, "curvature", point->curvature);
      np_mask_int(builder, "transition", point->state);
    }
    json_builder_end_object(builder);
  }
  json_builder_end_object(builder);
}

void np_masks_state(JsonBuilder *builder, dt_develop_t *dev)
{
  json_builder_set_member_name(builder, "maskState");
  json_builder_begin_object(builder);
  json_builder_set_member_name(builder, "forms");
  json_builder_begin_array(builder);
  for(GList *it = dev->forms; it; it = it->next)
  {
    const dt_masks_form_t *form = it->data;
    json_builder_begin_object(builder);
    np_mask_int(builder, "id", form->formid);
    np_mask_int(builder, "type", form->type);
    np_mask_int(builder, "version", form->version);
    np_mask_text(builder, "name", form->name);
    np_mask_write_point(builder, "source", form->source);
    geometry(builder, form);
    const size_t size = form->functions ? form->functions->point_struct_size : 0;
    GByteArray *bytes = g_byte_array_new();
    for(GList *point = form->points; size && point; point = point->next)
      g_byte_array_append(bytes, point->data, size);
    char *encoded = g_base64_encode(bytes->data, bytes->len);
    np_mask_text(builder, "pointData", encoded);
    g_free(encoded);
    g_byte_array_unref(bytes);
    json_builder_end_object(builder);
  }
  json_builder_end_array(builder);
  json_builder_set_member_name(builder, "blends");
  json_builder_begin_array(builder);
  for(GList *it = dev->iop; it; it = it->next)
  {
    const dt_iop_module_t *module = it->data;
    if(module->iop_order == INT_MAX || !module->blend_params
        || !(module->flags() & IOP_FLAGS_SUPPORTS_BLENDING)) continue;
    const dt_develop_blend_params_t *blend = module->blend_params;
    json_builder_begin_object(builder);
    np_mask_text(builder, "operation", module->op);
    np_mask_int(builder, "instance", module->multi_priority);
    np_mask_int(builder, "version", dt_develop_blend_version());
    np_mask_int(builder, "colorSpace", blend->blend_cst);
    np_mask_int(builder, "mode", blend->blend_mode);
    np_mask_float(builder, "opacity", blend->opacity);
    np_mask_int(builder, "maskMode", blend->mask_mode);
    np_mask_int(builder, "maskID", blend->mask_id);
    np_mask_int(builder, "maskCombine", blend->mask_combine);
    np_mask_bool(builder, "supportsDrawnMasks", !(module->flags() & IOP_FLAGS_NO_MASKS));
    char *encoded = g_base64_encode((const guchar *)blend, sizeof(*blend));
    np_mask_text(builder, "parameters", encoded);
    g_free(encoded);
    json_builder_end_object(builder);
  }
  json_builder_end_array(builder);
  json_builder_end_object(builder);
}
