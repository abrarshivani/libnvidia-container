#!/usr/bin/env bash
# Copyright (c) NVIDIA CORPORATION.  All rights reserved.
#
# Licensed under the Apache License, Version 2.0 (the "License");
# you may not use this file except in compliance with the License.
# You may obtain a copy of the License at
#
#     http://www.apache.org/licenses/LICENSE-2.0
#
# Unless required by applicable law or agreed to in writing, software
# distributed under the License is distributed on an "AS IS" BASIS,
# WITHOUT WARRANTIES OR CONDITIONS OF ANY KIND, either express or implied.
# See the License for the specific language governing permissions and
# limitations under the License.

set -euo pipefail

OUTPUT="${OUTPUT:-THIRD_PARTY_NOTICES.md}"
GO_DIR="${GO_DIR:-src/nvcgo}"
MODULES_TXT="${MODULES_TXT:-${GO_DIR}/vendor/modules.txt}"
ROOT_MK="${ROOT_MK:-Makefile}"
DOCKER_MK="${DOCKER_MK:-mk/docker.mk}"

GO_PACKAGES=("./...")

PLATFORMS=(
    "linux/amd64"
    "linux/arm64"
    "linux/ppc64le"
)

# id|makefile|tar members|license files|notice sources|built when|SPDX|location path|location url
#
# The last two fields give the Location column. 'location path' is the license
# file inside the archive, and 'location url' is where that same file is served
# upstream; the two are compared byte for byte before either is written. A
# dependency with no linkable license file sets the path to 'none' and puts the
# reason in place of the url. That state is spelled out rather than left empty
# so that a dependency which later gains a license file cannot pick one up
# silently -- the absence has to be revisited by hand.
C_DEPS=(
    "elftoolchain|mk/elftoolchain.mk|common libelf||libelf common/_elftc.h common/elfdefinitions.h|WITH_LIBELF=no|BSD-2-Clause AND BSD-3-Clause|none|none in this release; the terms are the per-file notices reproduced below"
    "libtirpc|mk/libtirpc.mk||COPYING|src tirpc|WITH_TIRPC=yes|BSD-3-Clause|COPYING|https://git.linux-nfs.org/?p=steved/libtirpc.git;a=blob_plain;f=COPYING;hb=refs/tags/libtirpc-\$(VERSION_DASHED)"
    "nvidia-modprobe|mk/nvidia-modprobe.mk|modprobe-utils||modprobe-utils|always|MIT|none|not the archive's COPYING, which is GPL-2.0 and covers binaries this repository does not ship; the terms are the per-file notices reproduced below"
)

NOTICE_SOURCE_RE='\.(c|h|m4)$'

BLOCK_SEP='@@@LIBNVIDIA-CONTAINER-NOTICE-BLOCK@@@'

die() {
    printf 'ERROR: %s\n' "$1" >&2
    shift
    if (( $# > 0 )); then
        printf '%s\n' "$@" >&2
    fi
    exit 1
}

log() {
    printf '%s\n' "$*" >&2
}

code_fence_for() {
    local file="$1" longest_backtick_run fence_width
    longest_backtick_run=$(LC_ALL=C grep -oaE '`+' "${file}" 2>/dev/null \
        | LC_ALL=C awk '
            { if (length($0) > longest) longest = length($0) }
            END { print longest+0 }
        ')
    fence_width=$(( longest_backtick_run + 1 ))
    (( fence_width < 3 )) && fence_width=3
    printf '%*s' "${fence_width}" '' | tr ' ' '`'
}

check_prerequisites() {
    local required_command
    for required_command in go curl tar iconv; do
        command -v "${required_command}" >/dev/null 2>&1 \
            || die "${required_command} is not installed."
    done

    local -a build_hint=(
        "Build it with 'make bin/go-licenses', or, where the root Makefile does not run, with that target's recipe:"
        "  (cd deployments/devel && GOBIN='${PWD}/bin' GOFLAGS=-mod=readonly go install github.com/google/go-licenses/v2)"
    )
    if ./bin/go-licenses --help >/dev/null 2>&1; then
        GO_LICENSES="${PWD}/bin/go-licenses"
    elif command -v go-licenses >/dev/null 2>&1; then
        GO_LICENSES="$(command -v go-licenses)"
    elif [[ -e "./bin/go-licenses" ]]; then
        die "./bin/go-licenses could not be run; it was most likely built for another platform." \
            "Delete it first." "${build_hint[@]}"
    else
        die "go-licenses is not installed." "${build_hint[@]}"
    fi

    local required_file dependency_record
    for required_file in "${ROOT_MK}" "${DOCKER_MK}" "${MODULES_TXT}"; do
        [[ -f "${required_file}" ]] \
            || die "${required_file} not found — run 'make third-party-notices' from the repo root."
    done
    for dependency_record in "${C_DEPS[@]}"; do
        required_file="$(printf '%s' "${dependency_record}" | cut -d'|' -f2)"
        [[ -f "${required_file}" ]] \
            || die "${required_file} not found — run 'make third-party-notices' from the repo root."
    done

    LOCAL_MODULE=$(cd "${GO_DIR}" && go list -m 2>/dev/null || true)
    [[ -n "${LOCAL_MODULE}" ]] \
        || die "could not determine the local module path via 'go list -m' in ${GO_DIR}."
}

verify_platform_matrix() {
    local released_platforms configured_platforms
    # shellcheck disable=SC2016  # '$(' is literal make syntax in the pattern.
    released_platforms=$(LC_ALL=C sed -n 's/^\$([A-Z0-9_]*TARGETS):[[:space:]]*ARCH[[:space:]]*:=[[:space:]]*//p' \
        "${DOCKER_MK}" \
        | sed -e 's/^x86_64$/amd64/' -e 's/^aarch64$/arm64/' \
        | sed 's|^|linux/|' \
        | LC_ALL=C sort -u)
    [[ -n "${released_platforms}" ]] \
        || die "could not read any 'ARCH :=' assignment from ${DOCKER_MK}."

    configured_platforms=$(printf '%s\n' "${PLATFORMS[@]}" | LC_ALL=C sort -u)
    [[ "${released_platforms}" == "${configured_platforms}" ]] || die \
        "the PLATFORMS matrix is out of sync with ${DOCKER_MK}." \
        "Update the PLATFORMS array in hack/generate-third-party-notices.sh to match the released targets." \
        "  matrix (PLATFORMS): $(echo "${configured_platforms}" | paste -sd ' ' -)" \
        "  docker.mk targets:  $(echo "${released_platforms}" | paste -sd ' ' -)"
}

prepare_workspace() {
    local work_dir_template="${TMPDIR:-/tmp}/libnvidia-container-notices"
    WORK_DIR="$(mktemp -d "${work_dir_template}.XXXXXX")"
    trap 'rm -rf "${WORK_DIR}"; rm -f "${OUT_TMP:-}"' EXIT

    LICENSES_DIR="${WORK_DIR}/licenses"
    GO_CSV="${WORK_DIR}/go.csv"
    GO_INDEX="${WORK_DIR}/go.index"
    C_INDEX="${WORK_DIR}/c.index"
    mkdir -p "${LICENSES_DIR}" "${WORK_DIR}/go"
    : > "${GO_CSV}"
    : > "${C_INDEX}"

    local output_dir
    output_dir="$(dirname "${OUTPUT}")"
    mkdir -p "${output_dir}"
    OUT_TMP="$(mktemp "${output_dir}/.$(basename "${OUTPUT}").XXXXXX")"
}

collect_go_licenses() {
    local platform goos goarch save_dir

    for platform in "${PLATFORMS[@]}"; do
        goos="${platform%/*}"
        goarch="${platform#*/}"
        log "Collecting Go licenses for ${goos}/${goarch}..."

        save_dir="${WORK_DIR}/save/${goos}_${goarch}"
        (
            cd "${GO_DIR}"
            export GOFLAGS="-mod=vendor" CGO_ENABLED=1
            GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" save "${GO_PACKAGES[@]}" \
                --save_path="${save_dir}" \
                --force \
                --ignore="${LOCAL_MODULE}" >&2
            GOOS="${goos}" GOARCH="${goarch}" "${GO_LICENSES}" csv "${GO_PACKAGES[@]}" \
                --ignore="${LOCAL_MODULE}"
        ) >> "${GO_CSV}"

        cp -R "${save_dir}/." "${LICENSES_DIR}/"
        chmod -R u+w "${LICENSES_DIR}"
    done
}

collapse_license_rows() {
    LC_ALL=C sort -u "$1" | LC_ALL=C awk -F, '
        {
            package_path = $1
            if (!(package_path in url)) {
                url[package_path] = $2
                package_order[++package_count] = package_path
            }
            if (!((package_path SUBSEP $3) in seen)) {
                seen[package_path SUBSEP $3] = 1
                licenses[package_path] = \
                    (license_count[package_path]++ ? licenses[package_path] " / " : "") $3
            }
        }
        END {
            for (i = 1; i <= package_count; i++)
                print package_order[i] "," url[package_order[i]] "," licenses[package_order[i]]
        }
    '
}

append_module_paths() {
    LC_ALL=C awk -v modules_txt="${MODULES_TXT}" '
        BEGIN {
            FS = OFS = ","
            while ((getline module_line < modules_txt) > 0) {
                if (module_line !~ /^# /) continue
                split(module_line, fields, " ")
                if (fields[4] == "=>" || fields[3] == "=>") {
                    replacement_field = (fields[4] == "=>") ? 5 : 4
                    if (fields[replacement_field + 1] == "") {
                        print "ERROR: " modules_txt " replaces " fields[2] " with a local path;" > "/dev/stderr"
                        print "teach hack/generate-third-party-notices.sh how to attribute it." > "/dev/stderr"
                        exit 1
                    }
                    module_paths[++module_count] = fields[2]
                    upstream_path[fields[2]] = fields[replacement_field]
                    upstream_version[fields[2]] = fields[replacement_field + 1]
                } else {
                    module_paths[++module_count] = fields[2]
                    upstream_path[fields[2]] = fields[2]
                    upstream_version[fields[2]] = fields[3]
                }
            }
            close(modules_txt)
            if (module_count == 0) {
                print "ERROR: no module lines read from " modules_txt > "/dev/stderr"
                exit 1
            }
        }
        {
            longest_match = ""
            for (i = 1; i <= module_count; i++) {
                module_path = module_paths[i]
                if (($1 == module_path || index($1, module_path "/") == 1) \
                    && length(module_path) > length(longest_match))
                    longest_match = module_path
            }
            print $0, (longest_match == "" ? "unknown" : upstream_path[longest_match]), \
                      (longest_match == "" ? "unknown" : upstream_version[longest_match])
        }
    '
}

build_go_index() {
    log "Building the Go dependency index..."
    collapse_license_rows "${GO_CSV}" | append_module_paths > "${GO_INDEX}"

    [[ -s "${GO_INDEX}" ]] \
        || die "go-licenses produced no entries for ${GO_PACKAGES[*]} in ${GO_DIR} — refusing to write an empty notices file."

    if cut -d, -f4 "${GO_INDEX}" | LC_ALL=C grep -qE '^$|^unknown$'; then
        die "some packages could not be matched to a module in ${MODULES_TXT}." \
            "Re-run 'go mod vendor' in ${GO_DIR}; if it persists, fix append_module_paths in hack/generate-third-party-notices.sh."
    fi

    if cut -d, -f5 "${GO_INDEX}" | LC_ALL=C grep -qE '^$|^unknown$'; then
        die "some packages could not be matched to a module version in ${MODULES_TXT}." \
            "Re-run 'go mod vendor' in ${GO_DIR} rather than committing rows without a version."
    fi

    if cut -d, -f3 "${GO_INDEX}" | LC_ALL=C grep -qE '^$|(^| / )Unknown( / |$)'; then
        die "go-licenses could not classify the license of some packages." \
            "Identify them by hand rather than committing a file that says Unknown."
    fi
}

read_make_var() {
    local file="$1" name="$2" value
    value=$(LC_ALL=C sed -n "s/^${name}[[:space:]]*:=[[:space:]]*//p" "${file}" | head -1)
    value="${value%"${value##*[![:space:]]}"}"
    [[ -n "${value}" ]] || die "could not read ${name} from ${file}."
    printf '%s' "${value}"
}

# Gerrit serves blobs base64-encoded behind ?format=TEXT; GitHub serves them
# raw. Everything downstream wants the decoded bytes.
fetch_license_bytes() {
    local url="$1" destination="$2" label="$3"
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --output "${destination}.encoded" "${url}" \
        || die "could not fetch the license location for ${label}:" \
               "  ${url}" \
               "This script needs network access; it will not write an unverified link."
    case "${url}" in
        *'?format=TEXT')
            # GNU coreutils spells the decode flag -d, BSD spells it -D.
            if base64 -d < "${destination}.encoded" > "${destination}" 2>/dev/null; then
                :
            elif base64 -D < "${destination}.encoded" > "${destination}" 2>/dev/null; then
                :
            else
                die "could not base64-decode the license location for ${label}:" "  ${url}"
            fi
            ;;
        *)
            mv -f "${destination}.encoded" "${destination}"
            ;;
    esac
}

# A link is only written once the bytes behind it match the copy reproduced in
# this document. A 200 proves nothing: upstream hosts serve the wrong revision
# for a plausible-looking URL often enough that status alone is not evidence.
verify_remote_matches() {
    local url="$1" local_file="$2" label="$3" remote_file="$4"
    local local_sha remote_sha
    fetch_license_bytes "${url}" "${remote_file}" "${label}"
    local_sha="$(sha256_of_file "${local_file}")"
    remote_sha="$(sha256_of_file "${remote_file}")"
    [[ "${local_sha}" == "${remote_sha}" ]] \
        || die "the license location for ${label} does not serve the bytes reproduced here." \
               "  url:             ${url}" \
               "  upstream sha256: ${remote_sha}" \
               "  local    sha256: ${local_sha}" \
               "Upstream may have retagged, or the URL points at a different revision."
}

sha256_of_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d' ' -f1
    else
        shasum -a 256 "$1" | cut -d' ' -f1
    fi
}

expand_make_vars() {
    local value="$1" version="$2" prefix="${3:-}"
    # libtirpc tags releases with the version's dots turned into dashes.
    value="${value//\$(VERSION_DASHED)/${version//./-}}"
    value="${value//\$(VERSION)/${version}}"
    value="${value//\$(PREFIX)/${prefix}}"
    # shellcheck disable=SC2016  # matching a literal '$(' left over by make.
    case "${value}" in
        *'$('*) die "unexpanded make variable in '${value}'." \
                    "Teach expand_make_vars in hack/generate-third-party-notices.sh about it." ;;
    esac
    printf '%s' "${value}"
}

extract_notice_blocks() {
    LC_ALL=C awk -v separator="${BLOCK_SEP}" '
        !in_block && /\/\*/ { in_block = 1; block = "" }
        in_block {
            line = $0
            sub(/[ \t]*\*\/[ \t]*$/, "", line)
            sub(/^[ \t]*\/\*[-*!]?[ \t]?/, "", line)
            sub(/^[ \t]*\*[ \t]?/, "", line)
            sub(/[ \t]+$/, "", line)
            if (line != "" || $0 !~ /\*\//) block = block line "\n"
            if ($0 ~ /\*\//) {
                if (block ~ /Copyright/) printf "%s%s\n", block, separator
                in_block = 0
            }
        }
    ' "$1"
}

dedupe_notice_blocks() {
    LC_ALL=C awk -v separator="${BLOCK_SEP}" '
        $0 == separator {
            gsub(/^\n+/, "", block)
            gsub(/\n+$/, "\n", block)
            if (block != "" && !(block in seen)) {
                seen[block] = 1
                if (emitted_blocks++) print "----------------------------------------------------------------------"
                printf "%s", block
            }
            block = ""
            next
        }
        { block = block $0 "\n" }
        END { printf "%d\n", emitted_blocks > "/dev/stderr" }
    '
}

# A location is written only when the bytes upstream are identical to the copy
# in the archive the build downloads. Status is not evidence: SourceForge's web
# view of libtirpc's COPYING answers 200 with a different revision of the file.
resolve_license_location() {
    local dependency_id="$1" location_path="$2" location_url="$3"
    local archive_file remote_file

    if [[ "${location_path}" == "none" ]]; then
        [[ -n "${location_url}" ]] \
            || die "${dependency_id} declares no license file but gives no reason." \
                   "Put the reason in the last field of its C_DEPS record."
        printf '%s' "${location_url}"
        return 0
    fi

    archive_file="${C_ROOT}/${location_path}"
    [[ -f "${archive_file}" ]] \
        || die "${dependency_id} ${C_VERSION} does not contain ${location_path}, which C_DEPS pins as its license file." \
               "Either the archive layout changed or the record is wrong."

    remote_file="${WORK_DIR}/c/${dependency_id}.location"
    verify_remote_matches "${location_url}" "${archive_file}" \
        "${dependency_id} ${C_VERSION} ${location_path}" "${remote_file}"

    printf '[%s](%s)' "${location_path}" "${location_url}"
}

fetch_c_dependency() {
    local dependency_id="$1" makefile="$2" tar_members="$3"
    local version prefix url decompress_flag unpack_dir tarball archive_root
    version="$(read_make_var "${makefile}" VERSION)"
    prefix="$(expand_make_vars "$(read_make_var "${makefile}" PREFIX)" "${version}")"
    url="$(expand_make_vars "$(read_make_var "${makefile}" URL)" "${version}" "${prefix}")"

    local decompressor
    case "${url}" in
        *.tar.bz2) decompress_flag="-j"; decompressor="bzip2" ;;
        *.tar.gz|*.tgz) decompress_flag="-z"; decompressor="gzip" ;;
        *) die "unsupported archive type for ${dependency_id}: ${url}" ;;
    esac
    command -v "${decompressor}" >/dev/null 2>&1 \
        || die "${decompressor} is required to unpack ${dependency_id} from ${url}, but is not installed."

    unpack_dir="${WORK_DIR}/c/${dependency_id}"
    tarball="${WORK_DIR}/${dependency_id}.tar"
    mkdir -p "${unpack_dir}"

    log "Fetching ${dependency_id} ${version} from ${url}..."
    curl --fail --silent --show-error --location --retry 3 --retry-delay 2 \
        --output "${tarball}" "${url}" \
        || die "failed to download ${dependency_id} ${version} from ${url}." \
               "This script needs network access; it will not emit a placeholder license."

    local -a member_args=()
    local member
    # shellcheck disable=SC2086  # the member list is a deliberate word split.
    for member in ${tar_members}; do
        member_args+=("${prefix}/${member}")
    done
    tar -C "${unpack_dir}" -x "${decompress_flag}" -f "${tarball}" \
        ${member_args[@]+"${member_args[@]}"} \
        || die "failed to unpack ${dependency_id} ${version} from ${url}."
    rm -f "${tarball}"

    archive_root="${unpack_dir}/${prefix}"
    [[ -d "${archive_root}" ]] \
        || die "${dependency_id} ${version} did not unpack into '${prefix}/' as ${makefile} expects."

    C_VERSION="${version}"
    C_URL="${url}"
    C_ROOT="${archive_root}"
}

collect_c_notices() {
    local dependency_record dependency_id makefile tar_members license_files
    local notice_paths build_condition declared_license location_path location_url
    local notices_file blocks_file path source_file scanned_file_count distinct_notice_count
    local location_cell

    for dependency_record in "${C_DEPS[@]}"; do
        IFS='|' read -r dependency_id makefile tar_members license_files \
            notice_paths build_condition declared_license location_path location_url \
            <<< "${dependency_record}"

        [[ -n "${location_path}" ]] \
            || die "${dependency_id} has no license-location field in C_DEPS." \
                   "Give it a path and a url, or 'none' and a reason."

        fetch_c_dependency "${dependency_id}" "${makefile}" "${tar_members}"

        notices_file="${WORK_DIR}/c/${dependency_id}.notices"
        blocks_file="${WORK_DIR}/c/${dependency_id}.blocks"
        : > "${notices_file}"
        : > "${blocks_file}"

        # shellcheck disable=SC2086  # the path lists are deliberate word splits.
        for path in ${license_files}; do
            [[ -f "${C_ROOT}/${path}" ]] \
                || die "${dependency_id} ${C_VERSION} does not contain ${path}, which ${makefile} pins as its license file."
            printf '%s\n' "--- ${path} ---" >> "${notices_file}"
            cat "${C_ROOT}/${path}" >> "${notices_file}"
        done

        scanned_file_count=0
        # shellcheck disable=SC2086
        for path in ${notice_paths}; do
            [[ -e "${C_ROOT}/${path}" ]] \
                || die "${dependency_id} ${C_VERSION} does not contain ${path}; update C_DEPS in hack/generate-third-party-notices.sh."
            while IFS= read -r source_file; do
                extract_notice_blocks "${source_file}" >> "${blocks_file}"
                scanned_file_count=$(( scanned_file_count + 1 ))
            done < <(find "${C_ROOT}/${path}" -type f | LC_ALL=C grep -E "${NOTICE_SOURCE_RE}" | LC_ALL=C sort)
        done
        (( scanned_file_count > 0 )) \
            || die "found no source files to scan for ${dependency_id} under: ${notice_paths}"

        dedupe_notice_blocks < "${blocks_file}" >> "${notices_file}" \
            2>"${WORK_DIR}/c/${dependency_id}.count"
        distinct_notice_count=$(tr -d '[:space:]' < "${WORK_DIR}/c/${dependency_id}.count")
        (( distinct_notice_count > 0 )) \
            || die "extracted no copyright notices from ${scanned_file_count} ${dependency_id} source files." \
                   "The comment format probably changed; fix extract_notice_blocks in hack/generate-third-party-notices.sh."

        [[ -s "${notices_file}" ]] \
            || die "no license text collected for ${dependency_id} ${C_VERSION}."

        location_cell="$(resolve_license_location "${dependency_id}" "${location_path}" \
            "$(expand_make_vars "${location_url}" "${C_VERSION}")")"

        printf '%s|%s|%s|%s|%s|%s|%s|%s|%s\n' \
            "${dependency_id}" "${C_VERSION}" "${build_condition}" "${declared_license}" \
            "${C_URL}" "${makefile}" "${scanned_file_count}" "${distinct_notice_count}" \
            "${location_cell}" >> "${C_INDEX}"
        log "  ${dependency_id} ${C_VERSION}: ${distinct_notice_count} distinct notices from ${scanned_file_count} files"
    done

    [[ -s "${C_INDEX}" ]] || die "no bundled C dependencies were collected."

    if cut -d'|' -f4 "${C_INDEX}" | LC_ALL=C grep -qE '^$|(^| )Unknown( |$)'; then
        die "a bundled C dependency has no declared license identifier." \
            "Fix its record in C_DEPS in hack/generate-third-party-notices.sh."
    fi
}

license_files_for() {
    local dir="$1" candidate_file
    [[ -d "${dir}" ]] || return 0
    while IFS= read -r -d '' candidate_file; do
        if printf '%s' "$(basename "${candidate_file}")" \
            | LC_ALL=C grep -qiE '^(licen[cs]e|notice|copying|copyright|authors|patents)([-._].*)?$'; then
            printf '%s\n' "${candidate_file}"
        fi
    done < <(find "${dir}" -maxdepth 1 -type f -print0 2>/dev/null | LC_ALL=C sort -z)
}

emit_fenced_file() {
    local file="$1" fence
    fence="$(code_fence_for "${file}")"
    printf '%stext\n' "${fence}"
    cat "${file}"
    echo
    printf '%s\n' "${fence}"
    echo
}

emit_c_table() {
    local dependency_id version build_condition declared_license url makefile
    local scanned_file_count distinct_notice_count location
    printf '| Dependency | Built when | License (declared) | Pinned in | Source | Location |\n'
    printf '|------------|------------|--------------------|-----------|--------|----------|\n'
    while IFS='|' read -r dependency_id version build_condition declared_license url makefile \
        scanned_file_count distinct_notice_count location; do
        [[ -z "${dependency_id}" ]] && continue
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '| `%s` | `%s` | %s | `%s` | %s | %s |\n' \
            "${dependency_id}" "${build_condition}" "${declared_license}" \
            "${makefile}" "${url}" "${location}"
    done < "${C_INDEX}"
}

emit_c_sections() {
    local dependency_id version build_condition declared_license url makefile
    local scanned_file_count distinct_notice_count location
    while IFS='|' read -r dependency_id version build_condition declared_license url makefile \
        scanned_file_count distinct_notice_count location; do
        [[ -z "${dependency_id}" ]] && continue
        printf '### %s\n\n' "${dependency_id}"
        printf '* Declared license: %s\n' "${declared_license}"
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '* Built when: `%s`\n' "${build_condition}"
        # shellcheck disable=SC2016
        printf '* Pinned in: `%s`\n' "${makefile}"
        printf '* Source: %s\n' "${url}"
        printf '* Notices: %s distinct, gathered from %s compiled or installed source files\n\n' \
            "${distinct_notice_count}" "${scanned_file_count}"
        emit_fenced_file "${WORK_DIR}/c/${dependency_id}.notices"
    done < "${C_INDEX}"
}

# Only the two module hosts this repository actually vendors are understood.
# Anything else stops the run rather than guessing a URL shape: a link that
# resolves to the wrong project is worse in a license document than no link.
go_license_url() {
    local module="$1" version="$2" file_name="$3" remainder organisation repository
    case "${module}" in
        github.com/*/*)
            remainder="${module#github.com/}"
            organisation="${remainder%%/*}"
            remainder="${remainder#*/}"
            repository="${remainder%%/*}"
            printf 'https://raw.githubusercontent.com/%s/%s/%s/%s' \
                "${organisation}" "${repository}" "${version}" "${file_name}"
            ;;
        golang.org/x/*)
            printf 'https://go.googlesource.com/%s/+/refs/tags/%s/%s?format=TEXT' \
                "${module#golang.org/x/}" "${version}" "${file_name}"
            ;;
        *)
            die "no license URL rule for the module ${module}." \
                "Add one to go_license_url in hack/generate-third-party-notices.sh;" \
                "this script will not guess a URL for a host it does not know."
            ;;
    esac
}

# Mirrors the C side: every file reproduced below gets a link, and the link is
# only kept once its bytes match that reproduction.
resolve_go_location() {
    local package_path="$1" module_path="$2" version="$3"
    local location_cell="" license_file file_name url remote_file package_path_slug
    package_path_slug="$(printf '%s' "${package_path}" | tr '/' '_')"
    while IFS= read -r license_file; do
        [[ -z "${license_file}" ]] && continue
        file_name="$(basename "${license_file}")"
        url="$(go_license_url "${module_path}" "${version}" "${file_name}")"
        remote_file="${WORK_DIR}/go/${package_path_slug}.${file_name}"
        verify_remote_matches "${url}" "${license_file}" \
            "${module_path} ${version} ${file_name}" "${remote_file}"
        location_cell="${location_cell:+${location_cell} / }[${file_name}](${url})"
    done < <(license_files_for "${LICENSES_DIR}/${package_path}")
    [[ -n "${location_cell}" ]] \
        || die "no license text was saved for ${package_path}; refusing to write a row without a verified location."
    printf '%s' "${location_cell}"
}

emit_go_table() {
    local package_path url license module_path version location
    printf '| Package | Version | License | Location |\n'
    printf '|---------|---------|---------|----------|\n'
    while IFS=, read -r package_path url license module_path version; do
        [[ -z "${package_path}" ]] && continue
        location="$(resolve_go_location "${package_path}" "${module_path}" "${version}")"
        # shellcheck disable=SC2016  # backticks are literal markdown here.
        printf '| `%s` | %s | %s | %s |\n' \
            "${package_path}" "${version}" "${license}" "${location}"
    done < "${GO_INDEX}"
}

emit_go_sections() {
    local package_path url license module_path version license_files license_file
    while IFS=, read -r package_path url license module_path version; do
        [[ -z "${package_path}" ]] && continue

        printf '### %s\n\n' "${package_path}"
        printf '* License: %s\n' "${license}"
        printf '* Module: %s\n\n' "${module_path}"

        license_files=()
        while IFS= read -r license_file; do
            [[ -n "${license_file}" ]] && license_files+=("${license_file}")
        done < <(license_files_for "${LICENSES_DIR}/${package_path}")

        (( ${#license_files[@]} > 0 )) \
            || die "no license text was saved for ${package_path}; refusing to write a notices file that omits it."

        for license_file in "${license_files[@]}"; do
            printf '#### %s\n\n' "$(basename "${license_file}")"
            emit_fenced_file "${license_file}"
        done
        echo
    done < "${GO_INDEX}"
}

emit_build_flags() {
    local file line
    printf '| Makefile | Rule |\n'
    printf '|----------|------|\n'
    for file in "${ROOT_MK}" "${DOCKER_MK}"; do
        while IFS= read -r line; do
            [[ -z "${line}" ]] && continue
            # shellcheck disable=SC2016  # backticks are literal markdown here.
            printf '| `%s` | `%s` |\n' "${file}" "${line}"
        done < <(LC_ALL=C grep -hE \
            -e '^WITH_(LIBELF|TIRPC)[[:space:]]*\??=' \
            -e '^[^[:space:]#]+:.*(WITH_LIBELF|WITH_TIRPC|tirpc)' \
            "${file}" | LC_ALL=C sed 's/[[:space:]]\{1,\}/ /g; s/[[:space:]]*$//')
    done
}

compose_document() {
    log "Composing ${OUTPUT}..."
    {
        cat <<'EOF'
# Third-Party Notices

NVIDIA libnvidia-container

This repository publishes deb and rpm packages containing
`libnvidia-container.so`, `libnvidia-container.a`, `libnvidia-container-go.so`
and the `nvidia-container-cli` binary. Third-party code is compiled into those
artifacts, and this file reproduces the terms that apply to it: the C sources
that `make deps` downloads and links in, and the Go modules vendored under
`src/nvcgo` and linked into `libnvidia-container-go.so`.

## Build configuration

Two of the bundled C dependencies are conditional, so which of them a given
package contains depends on how it was built. The defaults below apply to a
plain `make`, and `mk/docker.mk` overrides them per distribution target. Both
dependencies are documented here regardless of target, because packages are
published from several of these targets.

EOF
        emit_build_flags

        cat <<'EOF'

`nvidia-modprobe`'s `modprobe-utils` is unconditional: `make deps` always builds
it and `LIB_LDLIBS_STATIC` always links `libnvidia-modprobe-utils.a`.

## Bundled C Dependency Index

`Source` is the archive `make deps` downloads. `Location` is that dependency's
own license file upstream, pinned to the version built here; each link was
checked by fetching it and comparing it byte for byte with the copy inside the
archive. Where a dependency has no license file to link, the column says why.

EOF
        emit_c_table

        cat <<'EOF'

## Go Dependency Index

`Version` is the version vendored under `src/nvcgo/vendor` and linked into
`libnvidia-container-go.so`. `Location` is that version's own license file
upstream; as in the table above, each link was checked by fetching it and
comparing it byte for byte with the text reproduced below.

EOF
        emit_go_table

        cat <<'EOF'

## Bundled C Dependency License Texts

Each entry quotes every distinct copyright and license notice found in the
source files that are compiled or installed, plus the archive's own license file
where it has one. `nvidia-modprobe` is a special case worth spelling out: its
top-level `COPYING` is GPL-2.0 and covers the `nvidia-modprobe` binaries, which
this repository neither builds nor ships. Only `modprobe-utils/` is compiled in
here, and those files are individually MIT-licensed, so their per-file notices —
not the top-level `COPYING` — are what applies to this project's artifacts.

EOF
        emit_c_sections

        cat <<'EOF'
## Go Dependency License Texts

EOF
        emit_go_sections
    } > "${OUT_TMP}"

    iconv -f UTF-8 -t UTF-8 "${OUT_TMP}" >/dev/null 2>&1 \
        || die "the generated document is not valid UTF-8." \
               "A quoted license text is in a legacy encoding; transcode it in hack/generate-third-party-notices.sh."

    chmod 644 "${OUT_TMP}"
    mv "${OUT_TMP}" "${OUTPUT}"
}

main() {
    check_prerequisites
    verify_platform_matrix
    prepare_workspace

    collect_go_licenses
    build_go_index
    collect_c_notices

    compose_document

    local go_package_count c_dependency_count
    go_package_count=$(wc -l < "${GO_INDEX}" | tr -d ' ')
    c_dependency_count=$(wc -l < "${C_INDEX}" | tr -d ' ')
    log "Wrote ${OUTPUT} (${c_dependency_count} bundled C dependencies, ${go_package_count} Go packages)"
}

main "$@"
