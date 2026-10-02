#include "native_photo.h"
#include "common/exif.h"
#include "common/film.h"
#include "common/image_cache.h"
#include "develop/blend.h"
#include "develop/masks.h"

int main(int argc, char **argv)
{
  if(argc < 5 || dt_init(argc - 4, argv + 4, FALSE, FALSE, NULL)) return 2;
  char *directory = g_path_get_dirname(argv[1]);
  dt_film_t film;
  dt_film_init(&film);
  const dt_filmid_t filmid = dt_film_new(&film, directory);
  dt_film_cleanup(&film);
  g_free(directory);
  const dt_imgid_t imgid = dt_image_import(filmid, argv[1], TRUE, FALSE);
  if(!dt_is_valid_imgid(imgid)) return 3;
  dt_image_t *image = dt_image_cache_get(imgid, 'w');
  const gboolean failed = dt_exif_xmp_read(image, argv[2], FALSE);
  dt_image_cache_write_release(image, DT_IMAGE_CACHE_RELAXED);
  if(failed) return 4;
  dt_develop_t dev;
  dt_dev_init(&dev, FALSE);
  dt_dev_load_image(&dev, imgid);
  dt_dev_pop_history_items_ext(&dev, dev.history_end);
  dt_masks_form_t *path = dt_masks_create(DT_MASKS_PATH | DT_MASKS_CLONE);
  path->formid = 81999;
  path->source[0] = 0.31f;
  path->source[1] = 0.43f;
  g_strlcpy(path->name, "Preserved clone path", sizeof(path->name));
  for(int index = 0; index < 3; index++)
  {
    dt_masks_point_path_t *point = calloc(1, sizeof(*point));
    point->corner[0] = point->ctrl1[0] = point->ctrl2[0] = 0.2f + 0.1f * index;
    point->corner[1] = point->ctrl1[1] = point->ctrl2[1] = index == 1 ? 0.4f : 0.2f;
    point->border[0] = point->border[1] = 0.03f;
    point->state = DT_MASKS_POINT_STATE_USER;
    path->points = g_list_append(path->points, point);
  }
  dev.forms = g_list_append(dev.forms, path);
  dt_masks_form_t *future = dt_masks_create(DT_MASKS_ELLIPSE);
  future->formid = 81998;
  g_strlcpy(future->name, "Preserved unknown ellipse flags", sizeof(future->name));
  dt_masks_point_ellipse_t *ellipse = calloc(1, sizeof(*ellipse));
  ellipse->center[0] = ellipse->center[1] = 0.5f;
  ellipse->radius[0] = 0.2f;
  ellipse->radius[1] = 0.1f;
  ellipse->border = 0.04f;
  ellipse->flags = 2;
  future->points = g_list_append(future->points, ellipse);
  dev.forms = g_list_append(dev.forms, future);
  dt_iop_module_t *module = dt_iop_get_module_by_op_priority(dev.iop, "exposure", 1);
  if(!module || !module->blend_params) return 5;
  module->blend_params->reserved[0] = 0xdecafbad;
  module->blend_params->reserved[1] = 0x12345678;
  dt_dev_add_masks_history_item_ext(&dev, module, module->enabled, TRUE);
  dt_dev_write_history_ext(&dev, imgid);
  const gboolean write_failed = dt_exif_xmp_write(imgid, argv[3], TRUE);
  dt_dev_cleanup(&dev);
  dt_cleanup();
  return write_failed ? 6 : 0;
}
