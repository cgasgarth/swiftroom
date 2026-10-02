#pragma once
#include "common/darktable.h"
#include "develop/develop.h"
#include "develop/imageop.h"
#include "mcp/dt_bridge.h"

char *np_pipeline(JsonObject *request, gboolean prepare, char **err);
gboolean np_apply_fields(dt_iop_module_t *module, JsonObject *fields, char **err);
gboolean np_white_balance(dt_develop_t *dev, double kelvin, double tint, char **err);
