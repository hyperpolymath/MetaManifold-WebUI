// SPDX-License-Identifier: AGPL-3.0-only
/// <reference types="vite/client" />

// vite/client already declares '*.module.css' (const classes); a local
// re-declaration here collided with it (TS2300 duplicate identifier) once
// lib checking was examined under the strict foundation and has been removed.
//
// Ambient declarations for untyped dependencies live in
// src/types/declarations.d.ts (FIXME(types)-marked per policy).
