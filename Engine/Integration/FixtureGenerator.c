#include "native_photo.h"
#include "common/exif.h"
#include "common/film.h"
#include "common/iop_order.h"
#include "develop/blend.h"
#include "develop/masks.h"

int main(int argc, char **argv)
{
  if(argc < 4 || dt_init(argc - 3, argv + 3, FALSE, FALSE, NULL)) return 2;
  char *directory = g_path_get_dirname(argv[1]);
  dt_film_t film;
  dt_film_init(&film);
  const dt_filmid_t filmid = dt_film_new(&film, directory);
  dt_film_cleanup(&film);
  g_free(directory);
  const dt_imgid_t imgid = dt_image_import(filmid, argv[1], TRUE, FALSE);
  if(!dt_is_valid_imgid(imgid)) return 3;
  dt_develop_t dev;
  dt_dev_init(&dev, FALSE);
  dt_dev_load_image(&dev, imgid);
  dt_dev_pop_history_items_ext(&dev, dev.history_end);
  dt_iop_module_t *base = dt_iop_get_module_by_op_priority(dev.iop, "exposure", 0);
  if(!base || base->so->get_introspection()->self_size != sizeof(dt_iop_module_t)) return 4;
  dt_iop_module_t *instance = dt_dev_module_duplicate_ext(&dev, base, TRUE);
  if(!instance) return 4;
  g_strlcpy(instance->multi_name, "Local spotlight", sizeof(instance->multi_name));
  instance->multi_name_hand_edited = TRUE;
  JsonObject *fields = json_object_new();
  json_object_set_double_member(fields, "exposure", 1.75);
  json_object_set_int_member(fields, "mode", 0);
  char *error = NULL;
  if(!np_apply_fields(instance, fields, &error)) { fprintf(stderr, "%s\n", error); return 5; }
  json_object_unref(fields);
  dt_masks_form_t *circle = dt_masks_create(DT_MASKS_CIRCLE);
  circle->formid = 81001;
  g_strlcpy(circle->name, "Integration circle", sizeof(circle->name));
  dt_masks_point_circle_t *point = calloc(1, sizeof(*point));
  point->center[0] = point->center[1] = 0.5f;
  point->radius = 0.18f;
  point->border = 0.12f;
  circle->points = g_list_append(circle->points, point);
  dt_masks_form_t *group = dt_masks_create(DT_MASKS_GROUP);
  group->formid = 81002;
  g_strlcpy(group->name, "Integration group", sizeof(group->name));
  dt_masks_point_group_t *member = calloc(1, sizeof(*member));
  member->formid = circle->formid;
  member->parentid = group->formid;
  member->state = DT_MASKS_STATE_USE | DT_MASKS_STATE_SHOW | DT_MASKS_STATE_UNION;
  member->opacity = 0.75f;
  group->points = g_list_append(group->points, member);
  dev.forms = g_list_append(dev.forms, circle);
  dev.forms = g_list_append(dev.forms, group);
  instance->blend_params->mask_mode = DEVELOP_MASK_ENABLED | DEVELOP_MASK_MASK;
  instance->blend_params->mask_id = group->formid;
  instance->blend_params->opacity = 65.0f;
  instance->blend_params->blend_mode = DEVELOP_BLEND_NORMAL2;
  instance->enabled = TRUE;
  dt_dev_add_masks_history_item_ext(&dev, instance, TRUE, TRUE);
  dt_iop_module_t *grading = dt_iop_get_module_by_op_priority(dev.iop, "colorbalancergb", 0);
  dt_iop_module_t *sigmoid = dt_iop_get_module_by_op_priority(dev.iop, "sigmoid", 0);
  if(!grading || !sigmoid || !dt_ioppr_check_can_move_after_iop(dev.iop, grading, sigmoid)
      || !dt_ioppr_move_iop_after(&dev, grading, sigmoid)) return 6;
  dt_dev_add_history_item_ext(&dev, grading, grading->enabled, TRUE);
  dt_dev_write_history_ext(&dev, imgid);
  const gboolean failed = dt_exif_xmp_write(imgid, argv[2], TRUE);
  dt_dev_cleanup(&dev);
  dt_cleanup();
  return failed ? 7 : 0;
}
