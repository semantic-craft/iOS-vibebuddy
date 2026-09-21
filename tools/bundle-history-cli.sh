#!/bin/bash
# Xcode build phase: compile this checkout's helper, then seal it before the app.
set -euo pipefail

package_dir="$SRCROOT/../VibeBuddyMac"
case "$CONFIGURATION" in
  Debug) cli_configuration=debug ;;
  *) cli_configuration=release ;;
esac
cli_build_args=(--package-path "$package_dir" --scratch-path "$package_dir/.build"
                --configuration "$cli_configuration" --product vibebuddy-mcp -j 2)
read -r -a cli_architectures <<< "$ARCHS"
for cli_architecture in "${cli_architectures[@]}"; do
  cli_build_args+=(--arch "$cli_architecture")
done
if [[ -n "${SDKROOT:-}" ]]; then cli_build_args+=(--sdk "$SDKROOT"); fi
/usr/bin/xcrun swift build "${cli_build_args[@]}"
cli_bin_dir=$(/usr/bin/xcrun swift build "${cli_build_args[@]}" --show-bin-path)
cli_destination="$TARGET_BUILD_DIR/$EXECUTABLE_FOLDER_PATH/vibebuddy-mcp"
/bin/mkdir -p "$(dirname "$cli_destination")"
# Xcode's strip phase only covers its own product; mirror it for the copied CLI
# (Release sets DEPLOYMENT_POSTPROCESSING=YES, Debug does not).
install_args=(-m 755)
if [[ "${DEPLOYMENT_POSTPROCESSING:-NO}" == YES && "${STRIP_INSTALLED_PRODUCT:-YES}" == YES ]]; then
  install_args+=(-s)
fi
/usr/bin/install "${install_args[@]}" "$cli_bin_dir/vibebuddy-mcp" "$cli_destination"
if [[ "${CODE_SIGNING_ALLOWED:-YES}" != NO ]]; then
  /usr/bin/codesign --force --options runtime --sign "${EXPANDED_CODE_SIGN_IDENTITY:--}" "$cli_destination"
fi
