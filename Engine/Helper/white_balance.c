/*
    This file is part of darktable,
    Copyright (C) 2009-2026 darktable developers.

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

#include "native_photo.h"
#include "external/cie_colorimetric_tables.c"
#define INITIALBLACKBODYTEMPERATURE 4000
#define DT_IOP_LOWEST_TEMPERATURE 1901
#define DT_IOP_HIGHEST_TEMPERATURE 25000
typedef double((*spd)(unsigned long int wavelength, double TempK));

/*
 * Bruce Lindbloom, "Spectral Power Distribution of a Blackbody Radiator"
 * http://www.brucelindbloom.com/Eqn_Blackbody.html
 */
static double _spd_blackbody(unsigned long int wavelength, double TempK)
{
  // convert wavelength from nm to m
  const long double lambda = (double)wavelength * 1e-9;

/*
 * these 2 constants were computed using following Sage code:
 *
 * (from http://physics.nist.gov/cgi-bin/cuu/Value?h)
 * h = 6.62606957 * 10^-34 # Planck
 * c= 299792458 # speed of light in vacuum
 * k = 1.3806488 * 10^-23 # Boltzmann
 *
 * c_1 = 2 * pi * h * c^2
 * c_2 = h * c / k
 *
 * print 'c_1 = ', c_1, ' ~= ', RealField(128)(c_1)
 * print 'c_2 = ', c_2, ' ~= ', RealField(128)(c_2)
 */

#define c1 3.7417715246641281639549488324352159753e-16L
#define c2 0.014387769599838156481252937624049081933L

  return (double)(c1 / (powl(lambda, 5) * (expl(c2 / (lambda * TempK)) - 1.0L)));

#undef c2
#undef c1
}

/*
 * Bruce Lindbloom, "Spectral Power Distribution of a CIE D-Illuminant"
 * http://www.brucelindbloom.com/Eqn_DIlluminant.html
 * and https://en.wikipedia.org/wiki/Standard_illuminant#Illuminant_series_D
 */
static double _spd_daylight(unsigned long int wavelength, double TempK)
{
  cmsCIExyY WhitePoint = { D65xyY.x, D65xyY.y, 1.0 };

  /*
   * Bruce Lindbloom, "TempK to xy"
   * http://www.brucelindbloom.com/Eqn_T_to_xy.html
   */
  cmsWhitePointFromTemp(&WhitePoint, TempK);

  const double M = (0.0241 + 0.2562 * WhitePoint.x - 0.7341 * WhitePoint.y),
               m1 = (-1.3515 - 1.7703 * WhitePoint.x + 5.9114 * WhitePoint.y) / M,
               m2 = (0.0300 - 31.4424 * WhitePoint.x + 30.0717 * WhitePoint.y) / M;

  const unsigned long int j
      = ((wavelength - cie_daylight_components[0].wavelength)
         / (cie_daylight_components[1].wavelength
            - cie_daylight_components[0].wavelength));

  return (cie_daylight_components[j].S[0] + m1 * cie_daylight_components[j].S[1]
          + m2 * cie_daylight_components[j].S[2]);
}

/*
 * Bruce Lindbloom, "Computing XYZ From Spectral Data (Emissive Case)"
 * http://www.brucelindbloom.com/Eqn_Spect_to_XYZ.html
 */
static cmsCIEXYZ _spectrum_to_XYZ(double TempK, spd I)
{
  cmsCIEXYZ Source = {.X = 0.0, .Y = 0.0, .Z = 0.0 };

  /*
   * Color matching functions
   * https://en.wikipedia.org/wiki/CIE_1931_color_space#Color_matching_functions
   */
  for(size_t i = 0; i < cie_1931_std_colorimetric_observer_count; i++)
  {
    const unsigned long int lambda =
      cie_1931_std_colorimetric_observer[0].wavelength
      + (cie_1931_std_colorimetric_observer[1].wavelength
         - cie_1931_std_colorimetric_observer[0].wavelength) * i;

    const double P = I(lambda, TempK);
    Source.X += P * cie_1931_std_colorimetric_observer[i].xyz.X;
    Source.Y += P * cie_1931_std_colorimetric_observer[i].xyz.Y;
    Source.Z += P * cie_1931_std_colorimetric_observer[i].xyz.Z;
  }

  // normalize so that each component is in [0.0, 1.0] range
  const double _max = fmax(fmax(Source.X, Source.Y), Source.Z);
  Source.X /= _max;
  Source.Y /= _max;
  Source.Z /= _max;

  return Source;
}

// TODO: temperature and tint cannot be disjoined! (here it assumes no tint)
static cmsCIEXYZ _temperature_to_XYZ(double TempK)
{
  if(TempK < DT_IOP_LOWEST_TEMPERATURE) TempK = DT_IOP_LOWEST_TEMPERATURE;
  if(TempK > DT_IOP_HIGHEST_TEMPERATURE) TempK = DT_IOP_HIGHEST_TEMPERATURE;

  if(TempK < INITIALBLACKBODYTEMPERATURE)
  {
    // if temperature is less than 4000K we use blackbody,
    // because there will be no Daylight reference below 4000K...
    return _spectrum_to_XYZ(TempK, _spd_blackbody);
  }
  else
  {
    return _spectrum_to_XYZ(TempK, _spd_daylight);
  }
}

static cmsCIEXYZ _temperature_tint_to_XYZ(double TempK, double tint)
{
  cmsCIEXYZ xyz = _temperature_to_XYZ(TempK);

  xyz.Y /= tint; // TODO: This is baaad!

  return xyz;
}


gboolean np_white_balance(dt_develop_t *dev, double kelvin, double tint, char **err)
{
  dt_iop_module_t *module = dt_iop_get_module_by_op_priority(dev->iop, "temperature", 0);
  if(!module) { *err = g_strdup("white balance module unavailable"); return FALSE; }
  double xyz_to_cam[4][3], cam_to_xyz[3][4];
  if(!dt_colorspaces_conversion_matrices_xyz(dev->image_storage.adobe_XYZ_to_CAM,
      dev->image_storage.d65_color_matrix, xyz_to_cam, cam_to_xyz))
  { *err = g_strdup("camera color matrix unavailable for white balance"); return FALSE; }
  cmsCIEXYZ xyz = _temperature_tint_to_XYZ(kelvin, pow(2.0, tint / 100.0));
  double white[3] = { xyz.X, xyz.Y, xyz.Z }, mul[4];
  for(int row = 0; row < 4; row++)
  {
    double value = 0;
    for(int col = 0; col < 3; col++) value += xyz_to_cam[row][col] * white[col];
    mul[row] = value > 0 ? 1.0 / value : 0;
  }
  if(mul[1] <= 0) { *err = g_strdup("invalid white balance matrix"); return FALSE; }
  JsonObject *fields = json_object_new();
  const char *names[] = { "red", "green", "blue", "various" };
  for(int i = 0; i < 4; i++) json_object_set_double_member(fields, names[i], mul[i] / mul[1]);
  json_object_set_int_member(fields, "preset", -1);
  const gboolean ok = np_apply_fields(module, fields, err);
  json_object_unref(fields);
  if(ok) { module->enabled = TRUE; dt_dev_add_history_item_ext(dev, module, TRUE, TRUE); }
  return ok;
}
