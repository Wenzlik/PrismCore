// Copyright 2026 PrismCore contributors.
// Licensed under the Apache License, Version 2.0 (see LICENSE-APACHE in this directory).

//! TrueHD Atmos objects rendered to 7.1.4, behind the C API in `include/TrueHDObjects`.
//! TrueHD only: no DTS code is linked.

pub mod decode;
mod ffi;
mod limit;
pub mod render;
