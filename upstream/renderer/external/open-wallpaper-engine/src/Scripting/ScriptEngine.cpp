#include "Scripting/ScriptEngine.hpp"
#include "Scripting/ScriptModuleSyntax.hpp"

#include "Utils/TimeOfDay.hpp"

#include <cmath>
#include <mutex>
#include <new>

namespace wallpaper
{
namespace
{
[[maybe_unused]] constexpr char kVectorBootstrap[] = R"JS(
(function() {
  var EPSILON = 0.00001;
  var DEG2RAD = Math.PI / 180;
  var RAD2DEG = 180 / Math.PI;

  // Methods are defined the way `class` bodies define them: writable,
  // configurable, and not enumerable, so `for (k in vector)` lists only the
  // components.
  function define(target, methods) {
    Object.keys(methods).forEach(function(name) {
      Object.defineProperty(target, name, {
        value: methods[name], writable: true, configurable: true, enumerable: false
      });
    });
  }

  // A plain object handed to a vector constructor (the host and older scripts
  // pass `{x, y, z}`) is read leniently: a missing or non-finite field is 0.
  function lenient(value) {
    return typeof value === 'number' && Number.isFinite(value) ? value : 0;
  }

  var Vec2, Vec3, Vec4;

  function defineVector(name, fields) {
    var size = fields.length;
    var Vector;

    function make(values) {
      var instance = new Vector();
      for (var i = 0; i < size; ++i) instance[fields[i]] = values[i];
      return instance;
    }

    // Component `index` of an operand that is a number (applies to every
    // component) or a vector. A Vec2 beside a Vec3 or Vec4 stands for the
    // components it has; `rest` is what the arithmetic leaves of the others.
    function component(other, index, rest) {
      if (typeof other === 'number') return other;
      var value = other[fields[index]];
      if (value === undefined && rest !== undefined && other instanceof Vec2 && index >= 2) return rest;
      return value;
    }

    function combine(self, other, rest, op) {
      var values = new Array(size);
      for (var i = 0; i < size; ++i) values[i] = op(self[fields[i]], component(other, i, rest));
      return make(values);
    }

    function each(self, op) {
      var values = new Array(size);
      for (var i = 0; i < size; ++i) values[i] = op(self[fields[i]]);
      return make(values);
    }

    // `op` receives each component, the lower and the upper bound.
    function bounded(self, low, high, op) {
      var values = new Array(size);
      for (var i = 0; i < size; ++i) {
        values[i] = op(self[fields[i]], component(low, i), component(high, i));
      }
      return make(values);
    }

    Vector = class {
      constructor(a, b, c, d) {
        if (typeof a === 'string') {
          var parts = a.trim().split(/[\s,]+/);
          for (var i = 0; i < size; ++i) this[fields[i]] = parseFloat(parts[i]);
        } else if (a !== null && typeof a === 'object') {
          // Another vector keeps its values as they are; a plain `{x, y, ...}`
          // is read leniently. What either lacks is zero.
          var isVector = a instanceof Vec2 || a instanceof Vec3 || a instanceof Vec4;
          for (var j = 0; j < size; ++j) {
            var source = a[fields[j]];
            this[fields[j]] = isVector ? (source === undefined ? 0 : source) : lenient(source);
          }
        } else if (a === undefined) {
          for (var k = 0; k < size; ++k) this[fields[k]] = 0;
        } else {
          // A lone number fills every component. With a second number, the
          // components the call does not name are zero, and a Vec4 given three
          // numbers repeats the third as its fourth.
          var third = a;
          if (typeof c === 'number') third = c;
          else if (typeof b === 'number') third = 0;
          var set = [a,
                     typeof b === 'number' ? b : a,
                     third,
                     typeof d === 'number' ? d : third];
          for (var m = 0; m < size; ++m) this[fields[m]] = set[m];
        }
      }
    };
    Object.defineProperty(Vector, 'name', { value: name, configurable: true });

    define(Vector.prototype, {
      length: function() { return Math.sqrt(this.lengthSqr()); },
      lengthSqr: function() {
        var sum = 0;
        for (var i = 0; i < size; ++i) sum += this[fields[i]] * this[fields[i]];
        return sum;
      },
      distance: function(v) { return Math.sqrt(this.distanceSqr(v)); },
      distanceSqr: function(v) {
        var sum = 0;
        for (var i = 0; i < size; ++i) {
          var delta = this[fields[i]] - component(v, i);
          sum += delta * delta;
        }
        return sum;
      },
      normalize: function() { return this.divide(this.length()); },
      copy: function() { return each(this, function(value) { return value; }); },
      clone: function() { return this.copy(); },
      equals: function(other) {
        if (!(other instanceof Vector)) return false;
        for (var i = 0; i < size; ++i) {
          if (!(Math.abs(this[fields[i]] - other[fields[i]]) < EPSILON)) return false;
        }
        return true;
      },
      isFinite: function() {
        for (var i = 0; i < size; ++i) if (!Number.isFinite(this[fields[i]])) return false;
        return true;
      },
      negate: function() { return each(this, function(value) { return -value; }); },
      add: function(f) { return combine(this, f, 0, function(a, b) { return a + b; }); },
      subtract: function(f) { return combine(this, f, 0, function(a, b) { return a - b; }); },
      multiply: function(f) { return combine(this, f, 1, function(a, b) { return a * b; }); },
      divide: function(f) { return combine(this, f, 1, function(a, b) { return a / b; }); },
      dot: function(f) {
        var sum = 0;
        for (var i = 0; i < size; ++i) sum += this[fields[i]] * f[fields[i]];
        return sum;
      },
      reflect: function(normal) { return this.subtract(normal.multiply(this.dot(normal) * 2)); },
      // The part of this along `onto`; nothing when `onto` has no length.
      project: function(onto) {
        var lengthSquared = onto.lengthSqr();
        return lengthSquared === 0 ? each(this, function() { return 0; })
                                   : onto.multiply(this.dot(onto) / lengthSquared);
      },
      mix: function(other, amount) {
        var values = new Array(size);
        for (var i = 0; i < size; ++i) {
          var from = this[fields[i]];
          values[i] = from + (component(other, i) - from) * component(amount, i);
        }
        return make(values);
      },
      min: function(v) { return combine(this, v, undefined, function(a, b) { return Math.min(a, b); }); },
      max: function(v) { return combine(this, v, undefined, function(a, b) { return Math.max(a, b); }); },
      clamp: function(low, high) {
        return bounded(this, low, high, function(value, lo, hi) {
          return Math.max(lo, Math.min(hi, value));
        });
      },
      abs: function() { return each(this, Math.abs); },
      sign: function() { return each(this, Math.sign); },
      round: function() { return each(this, Math.round); },
      floor: function() { return each(this, Math.floor); },
      ceil: function() { return each(this, Math.ceil); },
      fract: function() { return each(this, function(value) { return value - Math.floor(value); }); },
      mod: function(v) {
        return combine(this, v, undefined, function(a, b) { return a - b * Math.floor(a / b); });
      },
      step: function(edge) {
        return combine(this, edge, undefined, function(a, b) { return a < b ? 0 : 1; });
      },
      smoothStep: function(low, high) {
        return bounded(this, low, high, function(value, lo, hi) {
          var t = Math.max(0, Math.min(1, (value - lo) / (hi - lo)));
          return t * t * (3 - 2 * t);
        });
      },
      toString: function() {
        var parts = new Array(size);
        for (var i = 0; i < size; ++i) parts[i] = String(this[fields[i]]);
        return parts.join(' ');
      },
      toConfigString: function() { return this.toString(); }
    });
    return Vector;
  }

  Vec2 = defineVector('Vec2', ['x', 'y']);
  Vec3 = defineVector('Vec3', ['x', 'y', 'z']);
  Vec4 = defineVector('Vec4', ['x', 'y', 'z', 'w']);

  define(Vec2.prototype, {
    perpendicular: function() { return new Vec2(this.y, -this.x); },
    angle: function() { return Math.atan2(this.y, this.x) * RAD2DEG; },
    // The signed angle from this vector to `v`: the cross product's z over the dot product.
    angleBetween: function(v) {
      var crossZ = this.x * v.y - this.y * v.x;
      var dotted = this.x * v.x + this.y * v.y;
      return Math.atan2(crossZ, dotted) * RAD2DEG;
    },
    rotate: function(degrees) {
      var turn = degrees * DEG2RAD;
      var cosine = Math.cos(turn);
      var sine = Math.sin(turn);
      return new Vec2(this.x * cosine - this.y * sine, this.x * sine + this.y * cosine);
    }
  });

  define(Vec3.prototype, {
    cross: function(v) {
      return new Vec3(this.y * v.z - this.z * v.y,
                      this.z * v.x - this.x * v.z,
                      this.x * v.y - this.y * v.x);
    },
    // Snell's law for a unit normal and a ratio of indices; zero past the
    // critical angle.
    refract: function(normal, eta) {
      var cosIncident = this.dot(normal);
      var radicand = 1 - eta * eta * (1 - cosIncident * cosIncident);
      return radicand < 0
          ? new Vec3(0, 0, 0)
          : normal.multiply(-(eta * cosIncident + Math.sqrt(radicand))).add(this.multiply(eta));
    },
    // The unsigned angle between the two; zero when either has no length.
    angleBetween: function(v) {
      var magnitude = Math.sqrt(this.lengthSqr() * v.lengthSqr());
      if (magnitude === 0) return 0;
      var cosine = Math.min(1, Math.max(-1, this.dot(v) / magnitude));
      return Math.acos(cosine) * RAD2DEG;
    },
    // (length, angle from +y, angle about +y from +x), in degrees.
    toSpherical: function() {
      var length = this.length();
      return length === 0
          ? new Vec3(0, 0, 0)
          : new Vec3(length, Math.acos(this.y / length) * RAD2DEG, Math.atan2(this.z, this.x) * RAD2DEG);
    }
  });
  define(Vec3, {
    fromSpherical: function(radius, polarDegrees, azimuthDegrees) {
      var polar = polarDegrees * DEG2RAD, azimuth = azimuthDegrees * DEG2RAD;
      var ring = radius * Math.sin(polar);
      return new Vec3(ring * Math.cos(azimuth), radius * Math.cos(polar), ring * Math.sin(azimuth));
    }
  });

  // ---- Matrices -------------------------------------------------------------
  // A matrix keeps its elements in `m`, column after column: in a matrix with
  // `side` rows and columns, the element in row r and column c is m[c * side + r].

  function identityArray(side) {
    var values = new Array(side * side).fill(0);
    for (var i = 0; i < side; ++i) values[i * side + i] = 1;
    return values;
  }

  function defineMatrix(name, side) {
    var count = side * side;
    var Matrix = class {
      // Another matrix, an array of the right length, or a string of numbers
      // gives its elements; anything else (or a wrong length) gives the identity.
      constructor(arg) {
        var elements = null;
        if (arg instanceof Matrix) elements = arg.m;
        else if (Array.isArray(arg)) elements = arg;
        else if (typeof arg === 'string') elements = arg.trim().split(/[\s,]+/).map(parseFloat);
        this.m = elements !== null && elements.length === count ? elements.slice() : identityArray(side);
      }
    };
    Object.defineProperty(Matrix, 'name', { value: name });
    return Matrix;
  }

  var Mat3 = defineMatrix('Mat3', 3);
  var Mat4 = defineMatrix('Mat4', 4);

  // The product a * b of two such arrays. Column c of the result combines the
  // columns of `a`, each weighted by the matching entry of column c of `b`.
  function product(a, b, side) {
    var out = new Array(side * side).fill(0);
    for (var col = 0; col < side; ++col) {
      for (var k = 0; k < side; ++k) {
        var weight = b[col * side + k];
        for (var row = 0; row < side; ++row) out[col * side + row] += a[k * side + row] * weight;
      }
    }
    return out;
  }

  // The array applied to a column of `side` numbers.
  function applyArray(array, side, column) {
    var out = new Array(side).fill(0);
    for (var col = 0; col < side; ++col) {
      for (var row = 0; row < side; ++row) out[row] += array[col * side + row] * column[col];
    }
    return out;
  }

  // Determinant of what is left of an n-by-n array when row `skipRow` and column
  // `skipColumn` are taken out (-1 takes out nothing), found by expanding along
  // the leftmost remaining column. `usedRows` is the set of rows already spent
  // by the columns to its left, as bits.
  function expand(a, n, column, skipColumn, usedRows) {
    if (column === skipColumn) column += 1;
    if (column >= n) return 1;
    var total = 0;
    var sign = 1;
    for (var row = 0; row < n; ++row) {
      if (usedRows & (1 << row)) continue;
      total += sign * a[column * n + row] * expand(a, n, column + 1, skipColumn, usedRows | (1 << row));
      sign = -sign;
    }
    return total;
  }

  function determinantOf(a, n) { return expand(a, n, 0, -1, 0); }

  // The inverse as the adjugate over the determinant: the element in row r and
  // column c is the minor that leaves out row c and column r, signed by the
  // parity of r + c, and divided by the determinant.
  function inverseOf(a, n) {
    var reciprocal = 1 / determinantOf(a, n);
    var out = new Array(n * n);
    for (var r = 0; r < n; ++r) {
      for (var c = 0; c < n; ++c) {
        var sign = (r + c) % 2 === 0 ? 1 : -1;
        out[c * n + r] = sign * expand(a, n, 0, r, 1 << c) * reciprocal;
      }
    }
    return out;
  }

  // The turn by `radians` about the coordinate axis k (0 x, 1 y, 2 z) of a
  // matrix with `side` rows. The other two axes follow k in cyclic order, and
  // the turn carries the first of them toward the second.
  function turnArray(side, k, radians) {
    var first = (k + 1) % 3;
    var second = (k + 2) % 3;
    var cosine = Math.cos(radians);
    var sine = Math.sin(radians);
    var out = identityArray(side);
    out[first * side + first] = cosine;
    out[second * side + second] = cosine;
    out[first * side + second] = sine;
    out[second * side + first] = -sine;
    return out;
  }

  // Column c of an array, as a Vec3 of its first three rows.
  function columnVec3(array, side, c) {
    return new Vec3(array[c * side], array[c * side + 1], array[c * side + 2]);
  }

  // A matrix with `scales` on its diagonal and ones where there are none.
  function diagonalArray(side, scales) {
    var out = identityArray(side);
    for (var i = 0; i < scales.length; ++i) out[i * side + i] = scales[i];
    return out;
  }

  // A matrix whose last column, above the corner, is `offset`.
  function offsetArray(side, offset) {
    var out = identityArray(side);
    for (var i = 0; i < offset.length; ++i) out[(side - 1) * side + i] = offset[i];
    return out;
  }

  // Methods that read the same for both sizes.
  function defineMatrixCommon(Matrix, side) {
    var count = side * side;
    define(Matrix.prototype, {
      add: function(other) {
        return new Matrix(this.m.map(function(value, i) { return value + other.m[i]; }));
      },
      subtract: function(other) {
        return new Matrix(this.m.map(function(value, i) { return value - other.m[i]; }));
      },
      copy: function() { return new Matrix(this); },
      equals: function(other) {
        return other instanceof Matrix &&
               this.m.every(function(value, i) { return Math.abs(value - other.m[i]) < EPSILON; });
      },
      transpose: function() {
        var result = new Matrix();
        for (var column = 0; column < side; ++column) {
          for (var row = 0; row < side; ++row) result.m[column * side + row] = this.m[row * side + column];
        }
        return result;
      },
      determinant: function() { return determinantOf(this.m, side); },
      inverse: function() { return new Matrix(inverseOf(this.m, side)); },
      toString: function() { return this.m.join(' '); },
      toConfigString: function() { return this.toString(); }
    });
    define(Matrix, {
      identity: function() { return new Matrix(); }
    });
  }
  defineMatrixCommon(Mat3, 3);
  defineMatrixCommon(Mat4, 4);

  // A scale argument is one number for every axis or a vector.
  var AXIS_NAMES = ['x', 'y', 'z'];
  function axisFactors(v, length) {
    var factors = [];
    for (var i = 0; i < length; ++i) factors.push(typeof v === 'number' ? v : v[AXIS_NAMES[i]]);
    return factors;
  }

  define(Mat3, {
    fromTranslation: function(v) { return new Mat3(offsetArray(3, [v.x, v.y])); },
    fromScale: function(v) { return new Mat3(diagonalArray(3, axisFactors(v, 2))); },
    fromRotation: function(degrees) { return new Mat3(turnArray(3, 2, degrees * DEG2RAD)); },
    fromBasis: function(right, up) {
      return new Mat3([right.x, right.y, 0, up.x, up.y, 0, 0, 0, 1]);
    },
    fromMat4: function(matrix) {
      var a = matrix.m;
      return new Mat3([a[0], a[1], a[2], a[4], a[5], a[6], a[8], a[9], a[10]]);
    },
    // Translate, then turn, then scale: T * R * S.
    compose: function(translation, rotation, scale) {
      var placed = product(offsetArray(3, [translation.x, translation.y]),
                           turnArray(3, 2, rotation * DEG2RAD), 3);
      return new Mat3(product(placed, diagonalArray(3, axisFactors(scale, 2)), 3));
    }
  });
  define(Mat3.prototype, {
    right: function() { return columnVec3(this.m, 3, 0); },
    up: function() { return columnVec3(this.m, 3, 1); },
    forward: function() { return columnVec3(this.m, 3, 2); },
    // With a Vec2 it sets the offset and answers the matrix; without, it answers the offset.
    translation: function(v) {
      if (!(v instanceof Vec2)) return new Vec2(this.m[6], this.m[7]);
      this.m.splice(6, 2, v.x, v.y);
      return this;
    },
    angle: function() { return Math.atan2(this.m[0], -this.m[1]) * RAD2DEG; },
    multiply: function(f) {
      if (f instanceof Mat3) return new Mat3(product(this.m, f.m, 3));
      if (f instanceof Vec3) {
        var moved = applyArray(this.m, 3, [f.x, f.y, f.z]);
        return new Vec3(moved[0], moved[1], moved[2]);
      }
      if (typeof f === 'number') return new Mat3(this.m.map(function(value) { return value * f; }));
    },
    translate: function(v) { return new Mat3(product(this.m, offsetArray(3, [v.x, v.y]), 3)); },
    rotate: function(degrees) { return new Mat3(product(this.m, turnArray(3, 2, degrees * DEG2RAD), 3)); },
    scale: function(v) { return new Mat3(product(this.m, diagonalArray(3, axisFactors(v, 2)), 3)); },
    transformPoint: function(v) {
      var moved = applyArray(this.m, 3, [v.x, v.y, 1]);
      return new Vec2(moved[0], moved[1]);
    },
    transformDirection: function(v) {
      var moved = applyArray(this.m, 3, [v.x, v.y, 0]);
      return new Vec2(moved[0], moved[1]);
    },
    // The x scale is negative when the upper 2x2 part mirrors the plane.
    decompose: function() {
      var m = this.m;
      var length = Math.hypot(m[0], m[1]);
      var xScale = expand(m, 3, 0, 2, 1 << 2) < 0 ? -length : length;
      return {
        translation: new Vec2(m[6], m[7]),
        rotation: xScale === 0 ? 0
                  : Math.atan2(xScale < 0 ? -m[1] : m[1], xScale < 0 ? -m[0] : m[0]) * RAD2DEG,
        scale: new Vec2(xScale, Math.hypot(m[3], m[4]))
      };
    }
  });

  define(Mat4, {
    fromTranslation: function(v) {
      var offset = [];
      if (v instanceof Vec3) offset = [v.x, v.y, v.z];
      else if (v instanceof Vec2) offset = [v.x, v.y];
      return new Mat4(offsetArray(4, offset));
    },
    fromScale: function(v) { return new Mat4(diagonalArray(4, axisFactors(v, 3))); },
    // Rotation by `degrees` about `axis`: cos * I + (1 - cos) * u u^T + sin * [u]x,
    // where u is the unit axis and [u]x the matrix that crosses a vector with it.
    fromRotation: function(degrees, axis) {
      var radians = degrees * DEG2RAD;
      var unit = axis.normalize();
      var u = [unit.x, unit.y, unit.z];
      var cosine = Math.cos(radians);
      var sine = Math.sin(radians);
      var crossing = [0, u[2], -u[1],  -u[2], 0, u[0],  u[1], -u[0], 0];
      var out = identityArray(4);
      for (var col = 0; col < 3; ++col) {
        for (var row = 0; row < 3; ++row) {
          out[col * 4 + row] = (row === col ? cosine : 0) + (1 - cosine) * u[row] * u[col] +
                               sine * crossing[col * 3 + row];
        }
      }
      return new Mat4(out);
    },
    // Turns about x, then y, then z, each about the fixed axes: Rz * Ry * Rx.
    fromEuler: function(x, y, z) {
      var angles = x instanceof Vec3 ? [x.x, x.y, x.z] : [x, y, z];
      var turned = identityArray(4);
      for (var axis = 2; axis >= 0; --axis) {
        turned = product(turned, turnArray(4, axis, angles[axis] * DEG2RAD), 4);
      }
      return new Mat4(turned);
    },
    fromBasis: function(right, up, forward) {
      return new Mat4([right.x, right.y, right.z, 0,
                       up.x, up.y, up.z, 0,
                       forward.x, forward.y, forward.z, 0,
                       0, 0, 0, 1]);
    },
    // The view matrix of a camera at `eye` looking at `center`: its rows are the
    // camera's side, above and (negated) ahead axes, then the eye moved to the origin.
    lookAt: function(eye, center, up) {
      var ahead = eye.multiply(-1).add(center).normalize();
      var side = ahead.cross(up).normalize();
      var above = side.cross(ahead);
      return new Mat4([side.x, above.x, -ahead.x, 0,
                       side.y, above.y, -ahead.y, 0,
                       side.z, above.z, -ahead.z, 0,
                       -side.dot(eye), -above.dot(eye), ahead.dot(eye), 1]);
    },
    // Translate, then turn, then scale: T * R * S.
    compose: function(translation, rotation, scale) {
      var placed = product(Mat4.fromTranslation(translation).m, Mat4.fromEuler(rotation).m, 4);
      return new Mat4(product(placed, diagonalArray(4, axisFactors(scale, 3)), 4));
    }
  });
  define(Mat4.prototype, {
    // With a Vec3 (or a Vec2, whose z is 0) it sets the offset and answers the
    // matrix; with anything else it answers the offset.
    translation: function(v) {
      if (!(v instanceof Vec3 || v instanceof Vec2)) return columnVec3(this.m, 4, 3);
      this.m.splice(12, 3, v.x, v.y, v instanceof Vec3 ? v.z : 0);
      return this;
    },
    right: function() { return columnVec3(this.m, 4, 0); },
    up: function() { return columnVec3(this.m, 4, 1); },
    forward: function() { return columnVec3(this.m, 4, 2); },
    multiply: function(f) {
      if (f instanceof Mat4) return new Mat4(product(this.m, f.m, 4));
      if (f instanceof Vec4) {
        var moved = applyArray(this.m, 4, [f.x, f.y, f.z, f.w]);
        return new Vec4(moved[0], moved[1], moved[2], moved[3]);
      }
      if (typeof f === 'number') return new Mat4(this.m.map(function(value) { return value * f; }));
    },
    translate: function(v) {
      var offset = [v.x, v.y, v instanceof Vec2 ? 0 : v.z];
      return new Mat4(product(this.m, offsetArray(4, offset), 4));
    },
    rotate: function(degrees, axis) { return this.multiply(Mat4.fromRotation(degrees, axis)); },
    scale: function(v) { return new Mat4(product(this.m, diagonalArray(4, axisFactors(v, 3)), 4)); },
    transformPoint: function(v) {
      var moved = applyArray(this.m, 4, [v.x, v.y, v.z, 1]);
      return new Vec3(moved[0], moved[1], moved[2]);
    },
    transformDirection: function(v) {
      var moved = applyArray(this.m, 4, [v.x, v.y, v.z, 0]);
      return new Vec3(moved[0], moved[1], moved[2]);
    },
    // The turns about x, y, z (degrees) that Mat4.fromEuler would compose into
    // this matrix, which is Rz * Ry * Rx. The x axis lands at (cos y cos z,
    // cos y sin z, -sin y), so z and y follow from the first column and the
    // length of the bottom row's other two entries. x is read after undoing the
    // turn about z: what remains is Ry * Rx, whose middle row is (0, cos x, -sin x),
    // and that stays defined where y is +-90 degrees and the bottom row vanishes.
    extractEuler: function() {
      var m = this.m;
      var yaw = Math.atan2(m[1], m[0]);
      var pitch = Math.atan2(-m[2], Math.hypot(m[6], m[10]));
      var rest = product(turnArray(4, 2, -yaw), m, 4);
      var roll = Math.atan2(-rest[9], rest[5]);
      return new Vec3(roll * RAD2DEG, pitch * RAD2DEG, yaw * RAD2DEG);
    },
    normalMatrix: function() { return Mat3.fromMat4(this).inverse().transpose(); },
    // Translation, Euler angles and scale. The x scale is negative when the
    // upper 3x3 part mirrors space.
    decompose: function() {
      var m = this.m;
      var scales = [];
      for (var col = 0; col < 3; ++col) scales.push(Math.hypot(m[col * 4], m[col * 4 + 1], m[col * 4 + 2]));
      if (expand(m, 4, 0, 3, 1 << 3) < 0) scales[0] = -scales[0];
      var rotation = new Mat4(this);
      for (var column = 0; column < 3; ++column) {
        if (scales[column] === 0) continue;
        for (var row = 0; row < 3; ++row) rotation.m[column * 4 + row] /= scales[column];
      }
      rotation.m[12] = 0; rotation.m[13] = 0; rotation.m[14] = 0;
      return {
        translation: new Vec3(m[12], m[13], m[14]),
        rotation: rotation.extractEuler(),
        scale: new Vec3(scales[0], scales[1], scales[2])
      };
    }
  });

  // The host builds its vectors and the layer matrices through these frozen
  // names, so a script that reassigns the global `Vec3` or `Mat4` cannot change
  // what the host hands back.
  var exposed = { Vec2: Vec2, Vec3: Vec3, Vec4: Vec4, Mat3: Mat3, Mat4: Mat4 };
  ['Vec2', 'Vec3', 'Vec4', 'Mat4'].forEach(function(key) {
    Object.defineProperty(globalThis, '__WE' + key, {
      value: exposed[key], configurable: false, writable: false
    });
  });
  Object.keys(exposed).forEach(function(key) {
    if (typeof globalThis[key] !== 'function') globalThis[key] = exposed[key];
  });
})();
)JS";

} // namespace

PropertyScriptProgram::PropertyScriptProgram(
    SceneRuntimeContext*, std::string, std::string, std::map<std::string, DynamicValue*>,
    DynamicValue, ScriptHostContext, JSRuntime*, JSContext*, std::string, std::string,
    PropertyScriptValueSemantic, int) {
    // CLEANROOM SC4
}

PropertyScriptProgram::~PropertyScriptProgram() {
    // CLEANROOM SC5
}

bool PropertyScriptProgram::Valid() const {
    // CLEANROOM SC6
    return false;
}

void PropertyScriptProgram::ApplyProjectProperties(const ProjectProperties&,
                                                   const ProjectProperties&) {
    // CLEANROOM SC7
}

DynamicValueUniquePtr PropertyScriptProgram::Evaluate(const ScriptHostContext&,
                                                      const DynamicValue&) {
    // CLEANROOM SC8
    return nullptr;
}

void PropertyScriptProgram::DispatchCursorClick(const ScriptHostContext&) {
    // CLEANROOM SC9
}

void PropertyScriptProgram::DispatchCursorDown(const ScriptHostContext&) {
    // CLEANROOM SC10
}

void PropertyScriptProgram::DispatchCursorEnter(const ScriptHostContext&) {
    // CLEANROOM SC11
}

void PropertyScriptProgram::DispatchCursorLeave(const ScriptHostContext&) {
    // CLEANROOM SC12
}

void PropertyScriptProgram::DispatchCursorMove(const ScriptHostContext&) {
    // CLEANROOM SC13
}

void PropertyScriptProgram::DispatchCursorUp(const ScriptHostContext&) {
    // CLEANROOM SC14
}

void PropertyScriptProgram::DispatchAnimationEvent(const ScriptHostContext&, std::string_view,
                                                   double) {
    // CLEANROOM SC15
}

void PropertyScriptProgram::DispatchMediaThumbnailChanged(const linalg::Vector3f&,
                                                          const linalg::Vector3f&) {
    // CLEANROOM SC16
}

void PropertyScriptProgram::DispatchMediaEventJson(std::string_view) {
    // CLEANROOM SC17
}

void PropertyScriptProgram::DispatchResizeScreen(const ScriptHostContext&) {
    // CLEANROOM SC18
}

void PropertyScriptProgram::DispatchGeneralSettings(const ScriptHostContext&) {
    // CLEANROOM SC19
}

void PropertyScriptProgram::Destroy() {
    // CLEANROOM SC20
}

SceneScriptProgram::SceneScriptProgram(SceneRuntimeContext&, std::string, std::string,
                                       ProjectProperties, ScriptHostContext, JSRuntime*,
                                       JSContext*, std::string) {
    // CLEANROOM SC21
}

SceneScriptProgram::~SceneScriptProgram() {
    // CLEANROOM SC22
}

bool SceneScriptProgram::Valid() const {
    // CLEANROOM SC23
    return false;
}

const std::string& SceneScriptProgram::LayerName() const {
    // CLEANROOM SC24
    static const std::string empty;
    return empty;
}

void SceneScriptProgram::ApplyUserProperties(const ProjectProperties&) {
    // CLEANROOM SC25
}

void SceneScriptProgram::ApplyProjectProperties(const ProjectProperties&,
                                                const ProjectProperties&) {
    // CLEANROOM SC26
}

void SceneScriptProgram::Tick(const ScriptHostContext&) {
    // CLEANROOM SC27
}

void SceneScriptProgram::DispatchCursorClick(const ScriptHostContext&) {
    // CLEANROOM SC28
}

void SceneScriptProgram::DispatchCursorDown(const ScriptHostContext&) {
    // CLEANROOM SC29
}

void SceneScriptProgram::DispatchCursorEnter(const ScriptHostContext&) {
    // CLEANROOM SC30
}

void SceneScriptProgram::DispatchCursorLeave(const ScriptHostContext&) {
    // CLEANROOM SC31
}

void SceneScriptProgram::DispatchCursorMove(const ScriptHostContext&) {
    // CLEANROOM SC32
}

void SceneScriptProgram::DispatchCursorUp(const ScriptHostContext&) {
    // CLEANROOM SC33
}

void SceneScriptProgram::DispatchAnimationEvent(const ScriptHostContext&, std::string_view,
                                                double) {
    // CLEANROOM SC34
}

void SceneScriptProgram::DispatchMediaThumbnailChanged(const linalg::Vector3f&,
                                                       const linalg::Vector3f&) {
    // CLEANROOM SC35
}

void SceneScriptProgram::DispatchMediaEventJson(std::string_view) {
    // CLEANROOM SC36
}

void SceneScriptProgram::DispatchResizeScreen(const ScriptHostContext&) {
    // CLEANROOM SC37
}

void SceneScriptProgram::DispatchGeneralSettings(const ScriptHostContext&) {
    // CLEANROOM SC38
}

void SceneScriptProgram::Destroy() {
    // CLEANROOM SC39
}

ScriptEngine::ScriptEngine() {
    // CLEANROOM SC40
}

ScriptEngine::~ScriptEngine() {
    // CLEANROOM SC41
}

void ScriptEngine::ResetStartupMetrics() {
    // CLEANROOM SC42
}

ScriptStartupMetrics ScriptEngine::GetStartupMetrics() {
    // CLEANROOM SC43
    return {};
}

DynamicValueUniquePtr ScriptEngine::Evaluate(const std::string&,
                                             const std::map<std::string, DynamicValue*>&,
                                             const DynamicValue&, const ScriptHostContext&) {
    // CLEANROOM SC44
    return nullptr;
}

std::unique_ptr<PropertyScriptProgram> ScriptEngine::CreatePropertyScriptProgram(
    SceneRuntimeContext*, std::string, std::string, std::map<std::string, DynamicValue*>,
    DynamicValue, ScriptHostContext, PropertyScriptValueSemantic, int) {
    // CLEANROOM SC45
    return nullptr;
}

std::unique_ptr<SceneScriptProgram> ScriptEngine::CreateSceneScriptProgram(
    SceneRuntimeContext&, std::string, std::string, ProjectProperties, ScriptHostContext) {
    // CLEANROOM SC46
    return nullptr;
}

void ScriptEngine::RunAnimationEventCallbacks(const ScriptHostContext&, std::string_view,
                                              double) {
    // CLEANROOM SC47
}

void ScriptEngine::RunResizeScreenCallbacks(const ScriptHostContext&) {
    // CLEANROOM SC48
}

void ScriptEngine::NotifyAnimationLayerEnded(const ScriptHostContext&, std::string_view, int) {
    // CLEANROOM SC49
}

} // namespace wallpaper
