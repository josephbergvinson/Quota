#!/bin/zsh

set -euo pipefail

script_directory="${0:A:h}"
repository_directory="${script_directory:h:h}"
output_directory="${1:-${repository_directory}/dist}"
version="${QUOTA_VERSION:-1.0.0}"
build_version="${QUOTA_BUILD_VERSION:-1}"

if [[ "${output_directory}" != /* ]]; then
    output_directory="${repository_directory}/${output_directory}"
fi
mkdir -p "${output_directory}"
output_directory="$(cd "${output_directory}" && pwd -P)"

if [[ "${output_directory}" == "/" || "${output_directory}" == "${repository_directory}" ]]; then
    print -u2 "Refusing to package into an unsafe output directory: ${output_directory}"
    exit 2
fi
if [[ ! "${version}" =~ '^[0-9]+\.[0-9]+\.[0-9]+$' ]]; then
    print -u2 "QUOTA_VERSION must contain three numeric components, such as 1.2.3."
    exit 2
fi
if [[ ! "${build_version}" =~ '^[1-9][0-9]*$' ]]; then
    print -u2 "QUOTA_BUILD_VERSION must be a positive integer."
    exit 2
fi

destination="${output_directory}/Quota.app"
staging_directory="$(mktemp -d "${TMPDIR:-/tmp}/quota-release.XXXXXX")"
staged_app="${staging_directory}/Quota.app"

cleanup() {
    rm -rf "${staging_directory}"
}
trap cleanup EXIT

build_for_architecture() {
    local architecture="$1"
    local triple="${architecture}-apple-macosx14.0"
    local scratch_path="${staging_directory}/build-${architecture}"
    local binary_directory

    swift build \
        --configuration release \
        --product Quota \
        --scratch-path "${scratch_path}" \
        --triple "${triple}" >&2
    binary_directory="$(swift build \
        --configuration release \
        --product Quota \
        --scratch-path "${scratch_path}" \
        --triple "${triple}" \
        --show-bin-path)"
    print -r -- "${binary_directory}/Quota"
}

cd "${repository_directory}"
arm64_binary="$(build_for_architecture arm64)"
x86_64_binary="$(build_for_architecture x86_64)"

mkdir -p "${staged_app}/Contents/MacOS" "${staged_app}/Contents/Resources"
lipo -create \
    "${arm64_binary}" \
    "${x86_64_binary}" \
    -output "${staged_app}/Contents/MacOS/Quota"
cp "${repository_directory}/Supporting/Info.plist" "${staged_app}/Contents/Info.plist"
/usr/libexec/PlistBuddy \
    -c "Set :CFBundleShortVersionString ${version}" \
    -c "Set :CFBundleVersion ${build_version}" \
    "${staged_app}/Contents/Info.plist"

iconset_directory="${staging_directory}/Quota.iconset"
mkdir -p "${iconset_directory}"
swift "${repository_directory}/Scripts/generate-icon.swift" \
    "${iconset_directory}/icon_512x512@2x.png"
for icon_spec in \
    "16:icon_16x16.png" \
    "32:icon_16x16@2x.png" \
    "32:icon_32x32.png" \
    "64:icon_32x32@2x.png" \
    "128:icon_128x128.png" \
    "256:icon_128x128@2x.png" \
    "256:icon_256x256.png" \
    "512:icon_256x256@2x.png" \
    "512:icon_512x512.png"
do
    icon_size="${icon_spec%%:*}"
    icon_name="${icon_spec#*:}"
    sips -z "${icon_size}" "${icon_size}" \
        "${iconset_directory}/icon_512x512@2x.png" \
        --out "${iconset_directory}/${icon_name}" >/dev/null
done
iconutil -c icns "${iconset_directory}" \
    -o "${staged_app}/Contents/Resources/Quota.icns"

plutil -lint "${staged_app}/Contents/Info.plist"
lipo "${staged_app}/Contents/MacOS/Quota" -verify_arch arm64 x86_64

case "${destination}" in
    */Quota.app) ;;
    *)
        print -u2 "Refusing to replace unexpected destination: ${destination}"
        exit 3
        ;;
esac
rm -rf "${destination}"
mv "${staged_app}" "${destination}"

# Sign only after the app reaches its final location. Finder and file-provider
# directories can add extended attributes during a move, invalidating a bundle
# that was signed while it was still in staging.
xattr -cr "${destination}"
codesign \
    --force \
    --sign - \
    --identifier com.jbergvinson.quota \
    --timestamp=none \
    "${destination}"
codesign --verify --deep --strict --verbose=2 "${destination}"
print "Built universal release app at ${destination}"
