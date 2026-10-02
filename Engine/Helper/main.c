#include "native_photo.h"

int main(int argc, char **argv)
{
  if(argc < 5) return 2;
  const char *command = argv[1];
  const char *response = argv[3];
  JsonParser *parser = json_parser_new();
  GError *error = NULL;
  if(!json_parser_load_from_file(parser, argv[2], &error))
  {
    fprintf(stderr, "%s\n", error->message);
    return 2;
  }
  JsonNode *root = json_parser_get_root(parser);
  if(!JSON_NODE_HOLDS_OBJECT(root)) return 2;
  JsonObject *request = json_node_get_object(root);
  if(dt_init(argc - 4, argv + 4, FALSE, FALSE, NULL)) return 3;
  guint introspected = 0;
  for(GList *it = darktable.iop; it; it = it->next)
  {
    dt_iop_module_so_t *module = it->data;
    if(!module->have_introspection || !module->get_introspection) continue;
    dt_introspection_t *layout = module->get_introspection();
    if(layout->api_version != DT_INTROSPECTION_VERSION
        || layout->self_size != sizeof(dt_iop_module_t)
        || layout->default_params != offsetof(dt_iop_module_t, default_params))
    {
      fprintf(stderr, "darktable module ABI layout mismatch: %s\n", module->op);
      dt_cleanup();
      return 3;
    }
    introspected++;
  }
  if(!introspected) { fprintf(stderr, "darktable introspection ABI unavailable\n"); dt_cleanup(); return 3; }
  char *err = NULL;
  char *json = NULL;
  if(!strcmp(command, "modules")) json = dt_bridge_list_modules_json();
  else if(!strcmp(command, "schema"))
    json = dt_bridge_module_schema_json(json_object_get_string_member(request, "operation"), &err);
  else if(!strcmp(command, "decode") || !strcmp(command, "encode"))
    json = np_parameters_json(request, !strcmp(command, "encode"), &err);
  else json = np_pipeline(request, !strcmp(command, "prepare"), &err);
  if(!json) fprintf(stderr, "%s\n", err ? err : "unknown error");
  const int status = json && g_file_set_contents(response, json, -1, NULL) ? 0 : 4;
  g_free(json);
  g_free(err);
  g_object_unref(parser);
  dt_cleanup();
  return status;
}
