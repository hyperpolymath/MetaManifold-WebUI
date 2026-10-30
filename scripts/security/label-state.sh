#!/bin/sh
# SPDX-License-Identifier: MPL-2.0
# Pure text classifiers for observed Linux security labels; not a security gate.
classify_apparmor_label() {
    case "$1" in
        '') printf '%s' unknown ;;
        unconfined|'unconfined ('*) printf '%s' unconfined ;;
        *) printf '%s' label-present ;;
    esac
}
classify_generic_label() {
    case "$1" in
        '') printf '%s' unknown ;;
        unconfined|'unconfined ('*) printf '%s' unconfined ;;
        *:*) printf '%s' label-present ;;
        *) printf '%s' unknown ;;
    esac
}
