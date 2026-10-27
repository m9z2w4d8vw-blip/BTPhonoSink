# External SBC implementation (build-time dependency)

The GitHub Actions workflow runs `tools/fetch_google_sbc.sh` to fetch the Apache-2.0 licensed Google libsbc sources at pinned commit `6e505650145c9973d08a0bdd5e5f5e1914305e40`. The source is copied here prior to compiling this auxiliary helper. No network access is required on iPhone. See https://github.com/google/libsbc. This folder initially contains only this README; a successful CI build must contain the four code files and upstream LICENSE.

The original research decoder in the tweak is unchanged and **not** used by `--sbc-play`.
