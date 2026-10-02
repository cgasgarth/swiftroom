/*
    This file is part of darktable,
    Copyright (C) 2026 darktable developers.

    darktable is free software: you can redistribute it and/or modify
    it under the terms of the GNU General Public License as published by
    the Free Software Foundation, either version 3 of the License, or
    (at your option) any later version.

    darktable is distributed in the hope that it will be useful,
    but WITHOUT ANY WARRANTY; without even the implied warranty of
    MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
    GNU General Public License for more details.

    You should have received a copy of the GNU General Public License
    along with darktable.  If not, see <http://www.gnu.org/licenses/>.
*/

#include "mcp/dt_bridge.h"

#include "common/colorspaces.h"
#include "common/darktable.h"
#include "control/conf.h"
#include "common/database.h"
#include "common/film.h"
#include "common/variables.h"
#include "common/image.h"
#include "common/image_cache.h"
#include "common/datetime.h"
#include "common/colorlabels.h"
#include "common/ratings.h"
#include "views/view.h"
#include "common/introspection.h"
#include "common/iop_order.h"
#include "common/history.h"
#include "common/styles.h"
#include "common/usermanual_url.h"
#include "develop/develop.h"
#include "develop/imageop.h"
#include "imageio/imageio_common.h"
#include "imageio/imageio_module.h"

#include <cairo/cairo.h>
#include <json-glib/json-glib.h>
#include <limits.h>
#include <sqlite3.h>
#include <stdlib.h>
#include <string.h>

// ---------------------------------------------------------------------------
// small helpers
// ---------------------------------------------------------------------------

// when set, every tool that would change the library refuses instead
static gboolean _read_only = FALSE;

void dt_bridge_set_read_only(const gboolean on)
{
  _read_only = on;
}

static void _seterr(char **err, const char *fmt, ...)
{
  if(!err) return;
  va_list ap;
  va_start(ap, fmt);
  *err = g_strdup_vprintf(fmt, ap);
  va_end(ap);
}

static uint8_t *_hex_to_bytes(const char *hex, size_t *outlen)
{
  if(!hex) return NULL;
  const size_t n = strlen(hex);
  if(n % 2) return NULL;
  const size_t bl = n / 2;
  uint8_t *b = g_malloc(bl ? bl : 1);
  for(size_t i = 0; i < bl; i++)
  {
    const int hi = g_ascii_xdigit_value(hex[2 * i]);
    const int lo = g_ascii_xdigit_value(hex[2 * i + 1]);
    if(hi < 0 || lo < 0)
    {
      g_free(b);
      return NULL;
    }
    b[i] = (uint8_t)((hi << 4) | lo);
  }
  *outlen = bl;
  return b;
}

static char *_bytes_to_hex(const uint8_t *b, size_t n)
{
  char *s = g_malloc(2 * n + 1);
  static const char hexd[] = "0123456789abcdef";
  for(size_t i = 0; i < n; i++)
  {
    s[2 * i] = hexd[b[i] >> 4];
    s[2 * i + 1] = hexd[b[i] & 0xf];
  }
  s[2 * n] = '\0';
  return s;
}

static dt_iop_module_so_t *_find_so(const char *op)
{
  if(!op) return NULL;
  return dt_iop_get_module_so(op);
}

// full usermanual URL for a module op, or NULL (caller frees)
static char *_doc_url(const char *op)
{
  const char *topic = dt_get_help_url(op); // pointer into a static table; do not free
  return topic ? dt_get_manual_url(topic) : NULL;
}

static void _add_doc_url(JsonBuilder *b, const char *op)
{
  char *url = _doc_url(op);
  if(url)
  {
    json_builder_set_member_name(b, "doc_url");
    json_builder_add_string_value(b, url);
    g_free(url);
  }
}

static const char *_type_name(dt_introspection_type_t t)
{
  switch(t)
  {
    case DT_INTROSPECTION_TYPE_FLOAT:  return "float";
    case DT_INTROSPECTION_TYPE_DOUBLE: return "double";
    case DT_INTROSPECTION_TYPE_INT:    return "int";
    case DT_INTROSPECTION_TYPE_UINT:   return "uint";
    case DT_INTROSPECTION_TYPE_INT8:   return "int8";
    case DT_INTROSPECTION_TYPE_UINT8:  return "uint8";
    case DT_INTROSPECTION_TYPE_SHORT:  return "short";
    case DT_INTROSPECTION_TYPE_USHORT: return "ushort";
    case DT_INTROSPECTION_TYPE_BOOL:   return "bool";
    case DT_INTROSPECTION_TYPE_ENUM:   return "enum";
    default:                           return "other";
  }
}

// is this a flat scalar leaf we can read/write generically?
static gboolean _is_scalar(dt_introspection_type_t t)
{
  switch(t)
  {
    case DT_INTROSPECTION_TYPE_FLOAT:
    case DT_INTROSPECTION_TYPE_DOUBLE:
    case DT_INTROSPECTION_TYPE_INT:
    case DT_INTROSPECTION_TYPE_UINT:
    case DT_INTROSPECTION_TYPE_INT8:
    case DT_INTROSPECTION_TYPE_UINT8:
    case DT_INTROSPECTION_TYPE_SHORT:
    case DT_INTROSPECTION_TYPE_USHORT:
    case DT_INTROSPECTION_TYPE_BOOL:
    case DT_INTROSPECTION_TYPE_ENUM:
      return TRUE;
    default:
      return FALSE;
  }
}

// read the scalar at p (of introspection type t) and add it to the builder
static void _add_value(JsonBuilder *b, dt_introspection_field_t *f, const void *p)
{
  switch(f->header.type)
  {
    case DT_INTROSPECTION_TYPE_FLOAT:
      json_builder_add_double_value(b, *(const float *)p);
      break;
    case DT_INTROSPECTION_TYPE_DOUBLE:
      json_builder_add_double_value(b, *(const double *)p);
      break;
    case DT_INTROSPECTION_TYPE_INT:
      json_builder_add_int_value(b, *(const int *)p);
      break;
    case DT_INTROSPECTION_TYPE_UINT:
      json_builder_add_int_value(b, *(const unsigned int *)p);
      break;
    case DT_INTROSPECTION_TYPE_INT8:
      json_builder_add_int_value(b, *(const int8_t *)p);
      break;
    case DT_INTROSPECTION_TYPE_UINT8:
      json_builder_add_int_value(b, *(const uint8_t *)p);
      break;
    case DT_INTROSPECTION_TYPE_SHORT:
      json_builder_add_int_value(b, *(const short *)p);
      break;
    case DT_INTROSPECTION_TYPE_USHORT:
      json_builder_add_int_value(b, *(const unsigned short *)p);
      break;
    case DT_INTROSPECTION_TYPE_BOOL:
      json_builder_add_boolean_value(b, (*(const gboolean *)p) != 0);
      break;
    case DT_INTROSPECTION_TYPE_ENUM:
    {
      const int v = *(const int *)p;
      const char *name = NULL;
      for(dt_introspection_type_enum_tuple_t *e = f->Enum.values; e && e->name; e++)
        if(e->value == v) { name = e->name; break; }
      if(name) json_builder_add_string_value(b, name);
      else     json_builder_add_int_value(b, v);
      break;
    }
    default:
      json_builder_add_null_value(b);
      break;
  }
}

// write default value of a scalar field into blob at p
static void _write_default(dt_introspection_field_t *f, void *p)
{
  switch(f->header.type)
  {
    case DT_INTROSPECTION_TYPE_FLOAT:  *(float *)p = f->Float.Default; break;
    case DT_INTROSPECTION_TYPE_DOUBLE: *(double *)p = f->Double.Default; break;
    case DT_INTROSPECTION_TYPE_INT:    *(int *)p = f->Int.Default; break;
    case DT_INTROSPECTION_TYPE_UINT:   *(unsigned int *)p = f->UInt.Default; break;
    case DT_INTROSPECTION_TYPE_INT8:   *(int8_t *)p = f->Int8.Default; break;
    case DT_INTROSPECTION_TYPE_UINT8:  *(uint8_t *)p = f->UInt8.Default; break;
    case DT_INTROSPECTION_TYPE_SHORT:  *(short *)p = f->Short.Default; break;
    case DT_INTROSPECTION_TYPE_USHORT: *(unsigned short *)p = f->UShort.Default; break;
    case DT_INTROSPECTION_TYPE_BOOL:   *(gboolean *)p = f->Bool.Default; break;
    case DT_INTROSPECTION_TYPE_ENUM:   *(int *)p = f->Enum.Default; break;
    default: break;
  }
}

// the bounds module_schema publishes. a field whose source carries no range
// comment gets its type's full range (introspection.h:77), so this only ever
// rejects what a module actually declares out of bounds
static gboolean _num_in_range(dt_introspection_field_t *f, const double num,
                              double *lo, double *hi)
{
  *lo = 0.0;
  *hi = 0.0;
  switch(f->header.type)
  {
    case DT_INTROSPECTION_TYPE_FLOAT:  *lo = f->Float.Min;  *hi = f->Float.Max;  break;
    case DT_INTROSPECTION_TYPE_DOUBLE: *lo = f->Double.Min; *hi = f->Double.Max; break;
    case DT_INTROSPECTION_TYPE_INT:    *lo = f->Int.Min;    *hi = f->Int.Max;    break;
    case DT_INTROSPECTION_TYPE_UINT:   *lo = f->UInt.Min;   *hi = f->UInt.Max;   break;
    case DT_INTROSPECTION_TYPE_INT8:   *lo = f->Int8.Min;   *hi = f->Int8.Max;   break;
    case DT_INTROSPECTION_TYPE_UINT8:  *lo = f->UInt8.Min;  *hi = f->UInt8.Max;  break;
    case DT_INTROSPECTION_TYPE_SHORT:  *lo = f->Short.Min;  *hi = f->Short.Max;  break;
    case DT_INTROSPECTION_TYPE_USHORT: *lo = f->UShort.Min; *hi = f->UShort.Max; break;
    default: return TRUE;   // bool and enum carry no range
  }
  return num >= *lo && num <= *hi;
}

static void _write_num(dt_introspection_field_t *f, void *p, double num)
{
  switch(f->header.type)
  {
    case DT_INTROSPECTION_TYPE_FLOAT:  *(float *)p = (float)num; break;
    case DT_INTROSPECTION_TYPE_DOUBLE: *(double *)p = num; break;
    case DT_INTROSPECTION_TYPE_INT:    *(int *)p = (int)num; break;
    case DT_INTROSPECTION_TYPE_UINT:   *(unsigned int *)p = (unsigned int)num; break;
    case DT_INTROSPECTION_TYPE_INT8:   *(int8_t *)p = (int8_t)num; break;
    case DT_INTROSPECTION_TYPE_UINT8:  *(uint8_t *)p = (uint8_t)num; break;
    case DT_INTROSPECTION_TYPE_SHORT:  *(short *)p = (short)num; break;
    case DT_INTROSPECTION_TYPE_USHORT: *(unsigned short *)p = (unsigned short)num; break;
    case DT_INTROSPECTION_TYPE_BOOL:   *(gboolean *)p = (num != 0.0); break;
    case DT_INTROSPECTION_TYPE_ENUM:   *(int *)p = (int)num; break;
    default: break;
  }
}

static char *_builder_to_string(JsonBuilder *b)
{
  JsonNode *root = json_builder_get_root(b);
  JsonGenerator *gen = json_generator_new();
  json_generator_set_root(gen, root);
  gchar *out = json_generator_to_data(gen, NULL);
  g_object_unref(gen);
  json_node_unref(root);
  return out;
}

// ---------------------------------------------------------------------------
// public API
// ---------------------------------------------------------------------------

char *dt_bridge_list_modules_json(void)
{
  JsonBuilder *b = json_builder_new();
  json_builder_begin_array(b);
  for(GList *m = darktable.iop; m; m = g_list_next(m))
  {
    dt_iop_module_so_t *so = (dt_iop_module_so_t *)m->data;
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "operation");
    json_builder_add_string_value(b, so->op);
    json_builder_set_member_name(b, "version");
    json_builder_add_int_value(b, so->version ? so->version() : -1);
    json_builder_set_member_name(b, "have_introspection");
    json_builder_add_boolean_value(b, so->have_introspection);
    _add_doc_url(b, so->op);
    json_builder_end_object(b);
  }
  json_builder_end_array(b);
  char *out = _builder_to_string(b);
  g_object_unref(b);
  return out;
}

char *dt_bridge_module_schema_json(const char *op, char **err)
{
  dt_iop_module_so_t *so = _find_so(op);
  if(!so)
  {
    _seterr(err, "unknown module operation '%s'", op ? op : "(null)");
    return NULL;
  }
  if(!so->have_introspection || !so->get_introspection || !so->get_introspection_linear)
  {
    _seterr(err, "module '%s' has no introspection", op);
    return NULL;
  }

  dt_introspection_t *intro = so->get_introspection();
  dt_introspection_field_t *lin = so->get_introspection_linear();

  JsonBuilder *b = json_builder_new();
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "operation");
  json_builder_add_string_value(b, so->op);
  json_builder_set_member_name(b, "params_version");
  json_builder_add_int_value(b, intro->params_version);
  json_builder_set_member_name(b, "params_size");
  json_builder_add_int_value(b, (gint64)intro->size);
  _add_doc_url(b, so->op);
  json_builder_set_member_name(b, "fields");
  json_builder_begin_array(b);

  for(dt_introspection_field_t *f = lin;
      f && f->header.type != DT_INTROSPECTION_TYPE_NONE; f++)
  {
    if(!_is_scalar(f->header.type)) continue;  // skip root struct / arrays / unions
    json_builder_begin_object(b);
    json_builder_set_member_name(b, "name");
    json_builder_add_string_value(b, f->header.field_name);
    json_builder_set_member_name(b, "type");
    json_builder_add_string_value(b, _type_name(f->header.type));
    json_builder_set_member_name(b, "offset");
    json_builder_add_int_value(b, (gint64)f->header.offset);
    switch(f->header.type)
    {
      case DT_INTROSPECTION_TYPE_FLOAT:
        json_builder_set_member_name(b, "min");
        json_builder_add_double_value(b, f->Float.Min);
        json_builder_set_member_name(b, "max");
        json_builder_add_double_value(b, f->Float.Max);
        json_builder_set_member_name(b, "default");
        json_builder_add_double_value(b, f->Float.Default);
        break;
      case DT_INTROSPECTION_TYPE_INT:
        json_builder_set_member_name(b, "min");
        json_builder_add_int_value(b, f->Int.Min);
        json_builder_set_member_name(b, "max");
        json_builder_add_int_value(b, f->Int.Max);
        json_builder_set_member_name(b, "default");
        json_builder_add_int_value(b, f->Int.Default);
        break;
      case DT_INTROSPECTION_TYPE_UINT:
        json_builder_set_member_name(b, "min");
        json_builder_add_int_value(b, f->UInt.Min);
        json_builder_set_member_name(b, "max");
        json_builder_add_int_value(b, f->UInt.Max);
        json_builder_set_member_name(b, "default");
        json_builder_add_int_value(b, f->UInt.Default);
        break;
      case DT_INTROSPECTION_TYPE_BOOL:
        json_builder_set_member_name(b, "default");
        json_builder_add_boolean_value(b, f->Bool.Default != 0);
        break;
      case DT_INTROSPECTION_TYPE_ENUM:
        json_builder_set_member_name(b, "default");
        json_builder_add_int_value(b, f->Enum.Default);
        json_builder_set_member_name(b, "values");
        json_builder_begin_array(b);
        for(dt_introspection_type_enum_tuple_t *e = f->Enum.values; e && e->name; e++)
        {
          json_builder_begin_object(b);
          json_builder_set_member_name(b, "name");
          json_builder_add_string_value(b, e->name);
          json_builder_set_member_name(b, "value");
          json_builder_add_int_value(b, e->value);
          json_builder_end_object(b);
        }
        json_builder_end_array(b);
        break;
      default: break;
    }
    json_builder_end_object(b);
  }

  json_builder_end_array(b);
  json_builder_end_object(b);
  char *out = _builder_to_string(b);
  g_object_unref(b);
  return out;
}

// write a { field: value, ... } object for all scalar fields of `blob`
static void _write_fields_object(dt_iop_module_so_t *so, const void *blob,
                                 JsonBuilder *b)
{
  dt_introspection_field_t *lin = so->get_introspection_linear();
  json_builder_begin_object(b);
  for(dt_introspection_field_t *f = lin;
      f && f->header.type != DT_INTROSPECTION_TYPE_NONE; f++)
  {
    if(!_is_scalar(f->header.type)) continue;
    void *p = so->get_p((void *)blob, f->header.name);
    if(!p) continue;
    json_builder_set_member_name(b, f->header.field_name);
    _add_value(b, f, p);
  }
  json_builder_end_object(b);
}

char *dt_bridge_decode_params_json(const char *op, const char *blob_hex, char **err)
{
  dt_iop_module_so_t *so = _find_so(op);
  if(!so)
  {
    _seterr(err, "unknown module operation '%s'", op ? op : "(null)");
    return NULL;
  }
  if(!so->have_introspection || !so->get_introspection || !so->get_p)
  {
    _seterr(err, "module '%s' has no introspection", op);
    return NULL;
  }

  size_t blen = 0;
  uint8_t *blob = _hex_to_bytes(blob_hex, &blen);
  if(!blob) { _seterr(err, "invalid hex blob"); return NULL; }

  dt_introspection_t *intro = so->get_introspection();
  if(blen != intro->size)
  {
    _seterr(err, "blob size %zu != module '%s' params size %zu"
                 " (version mismatch? pass the current version)",
            blen, op, intro->size);
    g_free(blob);
    return NULL;
  }

  JsonBuilder *b = json_builder_new();
  json_builder_begin_object(b);
  json_builder_set_member_name(b, "operation");
  json_builder_add_string_value(b, so->op);
  json_builder_set_member_name(b, "version");
  json_builder_add_int_value(b, intro->params_version);
  json_builder_set_member_name(b, "fields");
  _write_fields_object(so, blob, b);
  json_builder_end_object(b);

  char *out = _builder_to_string(b);
  g_object_unref(b);
  g_free(blob);
  return out;
}

// build a params blob from `defaults`, then overwrite the named fields.
// `defaults` is NULL when there is no module instance to take them from
static uint8_t *_seed_and_apply(dt_iop_module_so_t *so, const void *defaults,
                                JsonObject *fields, size_t *size, char **err)
{
  dt_introspection_t *intro = so->get_introspection();
  dt_introspection_field_t *lin = so->get_introspection_linear();

  uint8_t *blob = g_malloc0(intro->size);

  if(defaults)
  {
    // arrays and curve nodes come across intact, so having one no longer
    // rules out setting a module's scalar fields by name
    memcpy(blob, defaults, intro->size);
  }
  else
  {
    // only scalar defaults are reachable here, and a non-scalar left at
    // zero would be worse than refusing
    for(dt_introspection_field_t *f = lin;
        f && f->header.type != DT_INTROSPECTION_TYPE_NONE; f++)
      if(!_is_scalar(f->header.type) && f->header.size != intro->size)
      {
        _seterr(err, "module '%s' has non-scalar parameters; pass a full blob_hex"
                     " instead of fields", so->op);
        g_free(blob);
        return NULL;
      }

    for(dt_introspection_field_t *f = lin;
        f && f->header.type != DT_INTROSPECTION_TYPE_NONE; f++)
    {
      if(!_is_scalar(f->header.type)) continue;
      void *p = so->get_p(blob, f->header.name);
      if(p) _write_default(f, p);
    }
  }

  if(fields)
  {
    GList *members = json_object_get_members(fields);
    for(GList *it = members; it; it = g_list_next(it))
    {
      const char *name = (const char *)it->data;
      dt_introspection_field_t *f = so->get_f(name);
      if(!f || !_is_scalar(f->header.type))
      {
        _seterr(err, "unknown or non-scalar field '%s' for module '%s'", name, so->op);
        g_list_free(members);
        g_free(blob);
        return NULL;
      }
      void *p = so->get_p(blob, f->header.name);
      if(!p) continue;
      JsonNode *node = json_object_get_member(fields, name);
      if(f->header.type == DT_INTROSPECTION_TYPE_ENUM
         && json_node_get_value_type(node) == G_TYPE_STRING)
      {
        const char *sym = json_node_get_string(node);
        int val = 0;
        gboolean found = FALSE;
        for(dt_introspection_type_enum_tuple_t *e = f->Enum.values; e && e->name; e++)
          if(!g_strcmp0(e->name, sym)) { val = e->value; found = TRUE; break; }
        if(!found)
        {
          _seterr(err, "unknown enum value '%s' for field '%s'", sym, name);
          g_list_free(members);
          g_free(blob);
          return NULL;
        }
        *(int *)p = val;
      }
      else
      {
        // refuse rather than clamp: a silently corrected value would render
        // fine and leave the caller believing the number they sent was used
        const double num = json_node_get_double(node);
        double lo = 0.0, hi = 0.0;
        if(!_num_in_range(f, num, &lo, &hi))
        {
          _seterr(err, "field '%s' of module '%s' is %g, outside its range"
                       " [%g, %g] (see module_schema)", name, so->op, num, lo, hi);
          g_list_free(members);
          g_free(blob);
          return NULL;
        }
        _write_num(f, p, num);
      }
    }
    g_list_free(members);
  }

  *size = intro->size;
  return blob;
}

char *dt_bridge_encode_params_hex(const char *op, void *fields_jsonobject, char **err)
{
  dt_iop_module_so_t *so = _find_so(op);
  if(!so)
  {
    _seterr(err, "unknown module operation '%s'", op ? op : "(null)");
    return NULL;
  }
  if(!so->have_introspection || !so->get_introspection || !so->get_p || !so->get_f)
  {
    _seterr(err, "module '%s' has no introspection", op);
    return NULL;
  }

  size_t size = 0;
  uint8_t *blob = _seed_and_apply(so, NULL, (JsonObject *)fields_jsonobject, &size, err);
  if(!blob) return NULL;
  char *hex = _bytes_to_hex(blob, size);
  g_free(blob);
  return hex;
}


gboolean np_apply_fields(dt_iop_module_t *module, JsonObject *fields, char **err)
{
  if(!module->so->have_introspection)
  {
    _seterr(err, "module has no introspection");
    return FALSE;
  }
  size_t size = 0;
  uint8_t *blob = _seed_and_apply(module->so, module->params, fields, &size, err);
  if(!blob) return FALSE;
  const gboolean valid = size == (size_t)module->params_size;
  if(valid) memcpy(module->params, blob, size);
  else _seterr(err, "module parameter size mismatch");
  g_free(blob);
  return valid;
}
