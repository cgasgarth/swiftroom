#include "masks.h"

static gboolean mode_allowed(int colorspace, uint32_t mode)
{
  if(colorspace < DEVELOP_BLEND_CS_RAW || colorspace > DEVELOP_BLEND_CS_RGB_SCENE) return FALSE;
  if(mode == DEVELOP_BLEND_NORMAL2 || mode == DEVELOP_BLEND_DIFFERENCE2
      || mode == DEVELOP_BLEND_MULTIPLY || mode == DEVELOP_BLEND_ADD
      || mode == DEVELOP_BLEND_SUBTRACT || mode == DEVELOP_BLEND_SCREEN) return TRUE;
  if(colorspace == DEVELOP_BLEND_CS_RGB_SCENE) return mode == DEVELOP_BLEND_AVERAGE;
  return mode == DEVELOP_BLEND_LIGHTEN || mode == DEVELOP_BLEND_DARKEN;
}

static gboolean patch_number(JsonObject *patch, const char *key, double lower, double upper,
                             double *value, char **err)
{
  return !json_object_has_member(patch, key) || np_mask_number(patch, key, lower, upper, value, err);
}

gboolean np_blend_patch(dt_develop_t *dev, JsonObject *entry, char **err)
{
  const char *operation = json_object_get_string_member(entry, "operation");
  double instance, version;
  if(!operation || !np_mask_number(entry, "instance", 0, INT_MAX, &instance, err)
      || floor(instance) != instance || !np_mask_number(entry, "version", 14, 14, &version, err))
    return np_mask_fail(err, "blend identity/version is invalid");
  dt_iop_module_t *module = dt_iop_get_module_by_op_priority(dev->iop, operation, (int)instance);
  if(!module || !module->blend_params || !(module->flags() & IOP_FLAGS_SUPPORTS_BLENDING))
    return np_mask_fail(err, "module does not support blending");
  const char *seed = json_object_get_string_member(entry, "seed");
  if(!seed) return np_mask_fail(err, "blend patch requires accepted parameter bytes");
  gsize size = 0;
  guchar *data = g_base64_decode(seed, &size);
  const gboolean matched = size == sizeof(dt_develop_blend_params_t)
    && !memcmp(data, module->blend_params, size);
  g_free(data);
  if(!matched) return np_mask_fail(err, "blend seed differs from accepted state");
  JsonObject *patch = np_mask_object(entry, "patch");
  if(!patch) return np_mask_fail(err, "blend patch fields are unavailable");
  dt_develop_blend_params_t blend;
  memcpy(&blend, module->blend_params, sizeof(blend));
  double mode = blend.blend_mode & DEVELOP_BLEND_MODE_MASK, opacity = blend.opacity;
  double maskmode = blend.mask_mode, maskid = blend.mask_id, combine = blend.mask_combine;
  if(!patch_number(patch, "mode", 0, UINT32_MAX, &mode, err)
      || !patch_number(patch, "opacity", 0, 100, &opacity, err)
      || !patch_number(patch, "maskMode", 0, 15, &maskmode, err)
      || !patch_number(patch, "maskID", 0, INT32_MAX, &maskid, err)
      || !patch_number(patch, "maskCombine", 0, 7, &combine, err)) return FALSE;
  if(floor(mode) != mode || floor(maskmode) != maskmode || floor(maskid) != maskid || floor(combine) != combine)
    return np_mask_fail(err, "blend flags and identities must be integers");
  if(json_object_has_member(patch, "mode"))
  {
    if(!mode_allowed(blend.blend_cst, mode)) return np_mask_fail(err, "blend mode is inapplicable to this color space");
    blend.blend_mode = (blend.blend_mode & ~DEVELOP_BLEND_MODE_MASK) | (uint32_t)mode;
  }
  if(json_object_has_member(patch, "reversed"))
  {
    JsonNode *node = json_object_get_member(patch, "reversed");
    if(json_node_get_value_type(node) != G_TYPE_BOOLEAN) return np_mask_fail(err, "blend reversed flag is invalid");
    if(json_node_get_boolean(node)) blend.blend_mode |= DEVELOP_BLEND_REVERSE;
    else blend.blend_mode &= ~DEVELOP_BLEND_REVERSE;
  }
  if(json_object_has_member(patch, "opacity")) blend.opacity = opacity;
  if(json_object_has_member(patch, "maskMode"))
  {
    if(((uint32_t)maskmode & ~DEVELOP_MASK_ENABLED) && !((uint32_t)maskmode & DEVELOP_MASK_ENABLED))
      return np_mask_fail(err, "mask modes require enabled blending");
    if((module->flags() & IOP_FLAGS_NO_MASKS) && ((uint32_t)maskmode & ~DEVELOP_MASK_ENABLED))
      return np_mask_fail(err, "module does not support masks");
    if(((uint32_t)maskmode ^ blend.mask_mode) & (DEVELOP_MASK_CONDITIONAL | DEVELOP_MASK_RASTER))
      return np_mask_fail(err, "parametric/raster activation requires a supported dedicated editor");
    blend.mask_mode = maskmode;
  }
  if(json_object_has_member(patch, "maskID"))
  {
    const dt_masks_form_t *form = maskid ? dt_masks_get_from_id(dev, maskid) : NULL;
    if(maskid && (!form || !(form->type & DT_MASKS_GROUP)))
      return np_mask_fail(err, "module assignment requires an existing mask group");
    blend.mask_id = maskid;
  }
  if(json_object_has_member(patch, "maskCombine")) blend.mask_combine = combine;
  if((blend.mask_mode & DEVELOP_MASK_MASK) && (module->flags() & IOP_FLAGS_NO_MASKS))
    return np_mask_fail(err, "module does not support drawn masks");
  dt_iop_commit_blend_params(module, &blend);
  return TRUE;
}
