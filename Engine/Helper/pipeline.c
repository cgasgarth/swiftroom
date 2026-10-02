#include "native_photo.h"
#include "common/exif.h"
#include "common/film.h"
#include "common/image_cache.h"
#include "common/iop_order.h"
#include "control/conf.h"
#include "develop/blend.h"
#include "imageio/imageio_common.h"
#include "imageio/imageio_module.h"
#include "Masks/masks.h"

static double number(JsonObject *object, const char *key, double fallback)
{
  return json_object_has_member(object, key) ? json_object_get_double_member(object, key) : fallback;
}

static void text(JsonBuilder *builder, const char *key, const char *value)
{
  json_builder_set_member_name(builder, key);
  json_builder_add_string_value(builder, value ? value : "");
}

static void integer(JsonBuilder *builder, const char *key, gint64 value)
{
  json_builder_set_member_name(builder, key);
  json_builder_add_int_value(builder, value);
}

static void blob(JsonBuilder *builder, const char *key, const void *data, size_t length)
{
  char *encoded = g_base64_encode(data, length);
  text(builder, key, encoded);
  g_free(encoded);
}

static gboolean apply_modules(dt_develop_t *dev, JsonArray *entries, char **err)
{
  dt_iop_module_t *previous = NULL;
  double previous_order = -G_MAXDOUBLE;
  for(guint i = 0; entries && i < json_array_get_length(entries); i++)
  {
    JsonObject *entry = json_array_get_object_element(entries, i);
    const char *op = json_object_get_string_member(entry, "operation");
    const int priority = (int)number(entry, "instance", 0);
    dt_iop_module_t *module = dt_iop_get_module_by_op_priority(dev->iop, op, priority);
    if(!module)
    {
      dt_iop_module_t *base = dt_iop_get_module_by_op_priority(dev->iop, op, -1);
      if(!base || (base->flags() & IOP_FLAGS_ONE_INSTANCE))
      { *err = g_strdup_printf("module instance unavailable: %s/%d", op, priority); return FALSE; }
      module = dt_dev_module_duplicate_ext(dev, base, TRUE);
      if(!module) { *err = g_strdup("module duplication failed"); return FALSE; }
      dt_iop_update_multi_priority(module, priority);
    }
    const double desired_order = number(entry, "order", module->iop_order);
    if(desired_order < previous_order)
    { *err = g_strdup("module state must be sorted by requested pipeline order"); return FALSE; }
    if(previous && module->iop_order <= previous->iop_order)
    {
      if(!dt_ioppr_check_can_move_after_iop(dev->iop, module, previous)
          || !dt_ioppr_move_iop_after(dev, module, previous))
      { *err = g_strdup_printf("pipeline rules forbid placing %s after %s", op, previous->op); return FALSE; }
    }
    previous = module;
    previous_order = desired_order;
    if(module->version() != (int)number(entry, "version", -1))
    { *err = g_strdup_printf("module version mismatch: %s", op); return FALSE; }
    if(json_object_has_member(entry, "parameters"))
    {
      gsize size = 0;
      guchar *params = g_base64_decode(json_object_get_string_member(entry, "parameters"), &size);
      if(size != (gsize)module->params_size)
      { g_free(params); *err = g_strdup_printf("module blob size mismatch: %s", op); return FALSE; }
      memcpy(module->params, params, size);
      g_free(params);
    }
    if(json_object_has_member(entry, "fields") && !np_apply_fields(module,
        json_object_get_object_member(entry, "fields"), err)) return FALSE;
    if(json_object_has_member(entry, "blendParameters"))
    {
      gsize size = 0;
      guchar *params = g_base64_decode(json_object_get_string_member(entry, "blendParameters"), &size);
      if(size != sizeof(dt_develop_blend_params_t)
          || (int)number(entry, "blendVersion", -1) != dt_develop_blend_version())
      { g_free(params); *err = g_strdup_printf("blend version/size mismatch: %s", op); return FALSE; }
      dt_iop_commit_blend_params(module, (dt_develop_blend_params_t *)params);
      g_free(params);
    }
    if(json_object_has_member(entry, "name"))
    {
      const char *name = json_object_get_string_member(entry, "name");
      if(strlen(name) >= sizeof(module->multi_name))
      { *err = g_strdup("module instance label exceeds 127 UTF-8 bytes"); return FALSE; }
      if(strcmp(name, module->multi_name))
      {
        g_strlcpy(module->multi_name, name, sizeof(module->multi_name));
        module->multi_name_hand_edited = TRUE;
      }
    }
    module->enabled = json_object_get_boolean_member(entry, "enabled");
    const gboolean preserve_name = json_object_has_member(entry, "name");
    const gboolean hand_edited = module->multi_name_hand_edited;
    if(preserve_name) module->multi_name_hand_edited = TRUE;
    dt_dev_add_history_item_ext(dev, module, module->enabled, TRUE);
    if(preserve_name)
    {
      module->multi_name_hand_edited = hand_edited;
      dt_dev_history_item_t *item = g_list_nth_data(dev->history, dev->history_end - 1);
      if(item && item->module == module) item->multi_name_hand_edited = hand_edited;
    }
  }
  return TRUE;
}

static gboolean apply_adjustments(dt_develop_t *dev, JsonObject *edits, char **err)
{
  if(json_object_has_member(edits, "modules")
      && !apply_modules(dev, json_object_get_array_member(edits, "modules"), err)) return FALSE;
  const double ev = number(edits, "exposureEV", 0);
  if(ev != 0)
  {
    dt_iop_module_t *module = dt_iop_get_module_by_op_priority(dev->iop, "exposure", 0);
    if(!module) { *err = g_strdup("exposure module unavailable"); return FALSE; }
    dt_introspection_field_t *field = module->so->get_f("exposure");
    if(!field || field->header.type != DT_INTROSPECTION_TYPE_FLOAT)
    { *err = g_strdup("exposure introspection invalid"); return FALSE; }
    const float base = *(float *)module->so->get_p(module->params, "exposure");
    JsonObject *fields = json_object_new();
    json_object_set_double_member(fields, "exposure", base + ev);
    json_object_set_int_member(fields, "mode", 0);
    const gboolean ok = np_apply_fields(module, fields, err);
    json_object_unref(fields);
    if(!ok) return FALSE;
    module->enabled = TRUE;
    dt_dev_add_history_item_ext(dev, module, TRUE, TRUE);
  }
  JsonNode *temperature = json_object_get_member(edits, "temperature");
  const double tint = number(edits, "tint", 0);
  const gboolean has_temperature = temperature && !JSON_NODE_HOLDS_NULL(temperature);
  if((has_temperature || tint != 0)
      && !np_white_balance(dev, has_temperature ? json_node_get_double(temperature) : 0, tint, err)) return FALSE;
  return TRUE;
}

static char *response(dt_develop_t *dev, const char *xmp, int width, int height, cmsHPROFILE profile)
{
  JsonBuilder *builder = json_builder_new();
  json_builder_begin_object(builder);
  integer(builder, "pixelWidth", width);
  integer(builder, "pixelHeight", height);
  if(profile)
  {
    cmsUInt32Number length = 0;
    cmsSaveProfileToMem(profile, NULL, &length);
    void *data = g_malloc(length);
    cmsSaveProfileToMem(profile, data, &length);
    blob(builder, "outputICC", data, length);
    g_free(data);
  }
  json_builder_set_member_name(builder, "metadata");
  json_builder_begin_object(builder);
  integer(builder, "pixelWidth", dev->image_storage.width);
  integer(builder, "pixelHeight", dev->image_storage.height);
  text(builder, "camera", dev->image_storage.camera_makermodel);
  text(builder, "lens", dev->image_storage.exif_lens);
  integer(builder, "iso", (int)dev->image_storage.exif_iso);
  json_builder_end_object(builder);
  blob(builder, "darktableXMP", xmp, strlen(xmp));
  json_builder_set_member_name(builder, "modules");
  json_builder_begin_array(builder);
  for(GList *it = dev->iop; it; it = it->next)
  {
    dt_iop_module_t *module = it->data;
    if(module->iop_order == INT_MAX) continue;
    json_builder_begin_object(builder);
    text(builder, "operation", module->op);
    integer(builder, "version", module->version());
    integer(builder, "instance", module->multi_priority);
    integer(builder, "order", module->iop_order);
    json_builder_set_member_name(builder, "enabled");
    json_builder_add_boolean_value(builder, module->enabled);
    blob(builder, "parameters", module->params, module->params_size);
    if(module->blend_params)
    {
      blob(builder, "blendParameters", module->blend_params, sizeof(dt_develop_blend_params_t));
      integer(builder, "blendVersion", dt_develop_blend_version());
    }
    text(builder, "name", module->multi_name);
    json_builder_end_object(builder);
  }
  json_builder_end_array(builder);
  np_masks_state(builder, dev);
  json_builder_end_object(builder);
  JsonNode *root = json_builder_get_root(builder);
  JsonGenerator *generator = json_generator_new();
  json_generator_set_root(generator, root);
  char *json = json_generator_to_data(generator, NULL);
  g_object_unref(generator);
  json_node_unref(root);
  g_object_unref(builder);
  return json;
}

char *np_pipeline(JsonObject *request, gboolean prepare, char **err)
{
  const char *source = json_object_get_string_member(request, "source");
  char *directory = g_path_get_dirname(source);
  dt_film_t film;
  dt_film_init(&film);
  const dt_filmid_t filmid = dt_film_new(&film, directory);
  dt_film_cleanup(&film);
  g_free(directory);
  const dt_imgid_t imgid = dt_image_import(filmid, source, TRUE, FALSE);
  if(!dt_is_valid_imgid(imgid)) { *err = g_strdup("RAW import failed"); return NULL; }
  if(json_object_has_member(request, "xmp"))
  {
    dt_image_t *image = dt_image_cache_get(imgid, 'w');
    const gboolean failed = dt_exif_xmp_read(image, json_object_get_string_member(request, "xmp"), FALSE);
    dt_image_cache_write_release(image, DT_IMAGE_CACHE_RELAXED);
    if(failed) { *err = g_strdup("XMP import failed"); return NULL; }
  }
  dt_develop_t dev;
  dt_dev_init(&dev, FALSE);
  dt_dev_load_image(&dev, imgid);
  dt_dev_pop_history_items_ext(&dev, dev.history_end);
  JsonObject *edits = json_object_get_object_member(request, "edits");
  if(edits && !apply_adjustments(&dev, edits, err)) { dt_dev_cleanup(&dev); return NULL; }
  JsonObject *mask_edit = np_mask_object(request, "maskEdit");
  if(mask_edit && !np_masks_apply(&dev, mask_edit, err)) { dt_dev_cleanup(&dev); return NULL; }
  dt_dev_write_history_ext(&dev, imgid);
  int width = dev.image_storage.width, height = dev.image_storage.height;
  cmsHPROFILE output_profile = NULL;
  if(!prepare)
  {
    const char *format_name = json_object_get_string_member(request, "format");
    dt_imageio_module_format_t *format = dt_imageio_get_format_by_name(format_name);
    if(!format) { *err = g_strdup("export format unavailable"); dt_dev_cleanup(&dev); return NULL; }
    dt_conf_set_int("plugins/imageio/format/jpeg/quality", (int)number(request, "quality", 95));
    dt_conf_set_int("plugins/imageio/format/png/bpp", 16);
    dt_conf_set_int("plugins/imageio/format/tiff/bpp", 16);
    dt_imageio_module_data_t *data = format->get_params(format);
    data->max_width = data->max_height = (int)number(request, "maximumDimension", 0);
    data->style[0] = '\0';
    data->style_append = TRUE;
    const char *profile = json_object_get_string_member(request, "colorSpace");
    const dt_colorspaces_color_profile_type_t type = !strcmp(profile, "displayP3")
      ? DT_COLORSPACE_DISPLAY_P3 : !strcmp(profile, "adobeRGB") ? DT_COLORSPACE_ADOBERGB : DT_COLORSPACE_SRGB;
    output_profile = dt_colorspaces_get_output_profile(imgid, type, NULL)->profile;
    const gboolean failed = dt_imageio_export_with_flags(imgid,
      json_object_get_string_member(request, "destination"), format, data,
      FALSE, FALSE, TRUE, FALSE, FALSE, 1.0, FALSE, NULL, TRUE, FALSE,
      type, NULL, DT_INTENT_PERCEPTUAL, NULL, NULL, 1, 1, NULL, -1);
    width = data->width;
    height = data->height;
    format->free_params(format, data);
    if(failed) { *err = g_strdup("darktable export failed"); dt_dev_cleanup(&dev); return NULL; }
  }
  char *xmp = dt_exif_xmp_read_string(imgid);
  if(!xmp) { *err = g_strdup("XMP serialization failed"); dt_dev_cleanup(&dev); return NULL; }
  char *json = response(&dev, xmp, width, height, output_profile);
  g_free(xmp);
  dt_dev_cleanup(&dev);
  return json;
}
