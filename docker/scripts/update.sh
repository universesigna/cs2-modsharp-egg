#!/bin/bash
source /utils/logging.sh
source /utils/version.sh

# Directories
GAME_DIRECTORY="./game/csgo"
OUTPUT_DIR="./game/csgo/addons"
MODSHARP_DIR="./game/sharp"
TEMP_DIR="./temps"
VERSION_FILE="./game/versions.txt"

get_current_version() {
    local addon="$1"
    if [ -f "$VERSION_FILE" ]; then
        local version=$(grep "^$addon=" "$VERSION_FILE" | cut -d'=' -f2)
        echo "$version"
    else
        echo ""
    fi
}

create_modsharp_directories() {
    # Create required ModSharp directories
    log_message "Creating required ModSharp directories..." "running"
    mkdir -p "$MODSHARP_DIR/modules"
    mkdir -p "$MODSHARP_DIR/logs"
    mkdir -p "$MODSHARP_DIR/configs"
    mkdir -p "$MODSHARP_DIR/data"
    mkdir -p "$MODSHARP_DIR/shared"
    mkdir -p "$MODSHARP_DIR/assets"
    
    log_message "ModSharp directories created successfully" "running"
    return 0
}

copy_modsharp_files() {
    local source_dir="$1"
    local core_config="$MODSHARP_DIR/configs/core.config.kv"
    local backup_config=""
    
    log_message "Copying ModSharp files while preserving configurations..." "running"
    
    # Backup existing core.config.kv if it exists
    if [ -f "$core_config" ]; then
        backup_config="$TEMP_DIR/core.config.kv.backup"
        cp "$core_config" "$backup_config"
        log_message "Backed up existing core.config.kv" "running"
    fi
    
    # Copy all ModSharp files
    cp -rf "$source_dir/." "$MODSHARP_DIR/"
    
    # Restore the backed up config file if it existed
    if [ -n "$backup_config" ] && [ -f "$backup_config" ]; then
        cp "$backup_config" "$core_config"
        log_message "Restored existing core.config.kv configuration" "running"
        rm -f "$backup_config"
    fi
    
    return 0
}

update_version_file() {
    local addon="$1"
    local new_version="$2"
    
    # Create version file if it doesn't exist
    mkdir -p "$(dirname "$VERSION_FILE")"
    touch "$VERSION_FILE"
    
    if grep -q "^$addon=" "$VERSION_FILE" 2>/dev/null; then
        sed -i "s/^$addon=.*/$addon=$new_version/" "$VERSION_FILE"
        log_message "Updated $addon version to: $new_version" "running"
    else
        echo "$addon=$new_version" >> "$VERSION_FILE"
        log_message "Added $addon version: $new_version" "running"
    fi
}

# Download GitHub Actions artifact with authentication
download_github_artifact() {
    local artifact_url="$1"
    local output_file="$2"
    local artifact_name="$3"
    
    log_message "Downloading $artifact_name artifact..." "running"
    
    # Use -S to show errors even with -s (silent progress)
    local error_output
    error_output=$(curl -fsSL -H "Authorization: Bearer $GITHUB_TOKEN" \
                        -H "Accept: application/vnd.github+json" \
                        -H "X-GitHub-Api-Version: 2022-11-28" \
                        -o "$output_file" \
                        -w "%{http_code}" \
                        "$artifact_url" 2>&1)
    local exit_code=$?
    
    if [ $exit_code -ne 0 ]; then
        log_message "Failed to download $artifact_name artifact (exit code: $exit_code)" "error"
        if [ -n "$error_output" ]; then
            log_message "Error details: $error_output" "error"
        fi
        return 1
    fi
    
    # Verify file was downloaded and is not empty
    if [ ! -s "$output_file" ]; then
        log_message "Downloaded $artifact_name artifact is empty or missing" "error"
        return 1
    fi
    
    log_message "$artifact_name artifact downloaded successfully" "running"
    return 0
}

# Extract GitHub artifact (simple extraction, sharp folder is at root)
extract_github_artifact() {
    local artifact_zip="$1"
    local extract_base="$2"
    local artifact_name="$3"
    
    log_message "Extracting $artifact_name artifact..." "running"
    
    # Verify the zip file exists and is not empty
    if [ ! -s "$artifact_zip" ]; then
        log_message "Artifact zip file is missing or empty: $artifact_zip" "error"
        return 1
    fi
    
    # Extract the zip
    mkdir -p "$extract_base"
    if ! unzip -qq -o "$artifact_zip" -d "$extract_base" 2>&1; then
        log_message "Failed to extract $artifact_name artifact" "error"
        return 1
    fi
    
    # The sharp folder should be at the root of the extracted content
    if [ ! -d "$extract_base/sharp" ]; then
        log_message "No sharp folder found in $artifact_name artifact" "error"
        log_message "Contents of $extract_base:" "running"
        ls -la "$extract_base" 2>&1 | while read -r line; do
            log_message "  $line" "running"
        done
        return 1
    fi
    
    log_message "Successfully extracted $artifact_name artifact" "running"
    # Return the path to extracted content
    echo "$extract_base"
    return 0
}

# Install ModSharp artifact sharp folder
install_modsharp_artifact() {
    local artifact_url="$1"
    local artifact_name="$2"
    local is_core="${3:-false}"  # true for core install (with config preservation), false for overlay
    
    local artifact_file="$TEMP_DIR/modsharp-${artifact_name}.zip"
    local extract_base="$TEMP_DIR/modsharp-${artifact_name}"
    
    log_message "Artifact URL: $artifact_url" "running"
    
    # Download artifact
    if ! download_github_artifact "$artifact_url" "$artifact_file" "$artifact_name"; then
        log_message "Download failed for $artifact_name" "error"
        return 1
    fi
    
    # Extract artifact (returns path to extracted content)
    log_message "Starting extraction for $artifact_name..." "running"
    local extracted_path
    extracted_path=$(extract_github_artifact "$artifact_file" "$extract_base" "$artifact_name")
    local extract_result=$?
    
    log_message "Extraction result: $extract_result, path: $extracted_path" "running"
    
    if [ $extract_result -ne 0 ] || [ -z "$extracted_path" ]; then
        log_message "Extraction failed for $artifact_name (result: $extract_result)" "error"
        return 1
    fi
    
    # Verify sharp folder exists
    log_message "Checking for sharp folder in: $extracted_path" "running"
    if [ ! -d "$extracted_path/sharp" ]; then
        log_message "$artifact_name artifact structure not recognized - no sharp folder found" "error"
        log_message "Contents of $extracted_path:" "running"
        ls -la "$extracted_path" 2>&1 | while read -r line; do
            log_message "  $line" "running"
        done
        return 1
    fi
    
    log_message "Found sharp folder, proceeding with installation" "running"
    
    # Install files
    if [ "$is_core" = "true" ]; then
        log_message "Installing ModSharp core files..." "running"
        copy_modsharp_files "$extracted_path/sharp"
    else
        log_message "Installing ModSharp $artifact_name..." "running"
        cp -rf "$extracted_path/sharp/." "$MODSHARP_DIR/"
        log_message "ModSharp $artifact_name installed successfully" "success"
    fi
    
    return 0
}

# Centralized download and extract function
handle_download_and_extract() {
    local url="$1"
    local output_file="$2"
    local extract_dir="$3"
    local file_type="$4"  # "zip" or "tar.gz"

    log_message "Downloading from: $url" "running"

    # Download with timeout and retry
    local max_retries=3
    local retry=0
    while [ $retry -lt $max_retries ]; do
        if curl -fsSL -m 300 -o "$output_file" "$url"; then
            break
        fi
        ((retry++))
        log_message "Download attempt $retry failed, retrying..." "error"
        sleep 5
    done

    if [ $retry -eq $max_retries ]; then
        log_message "Failed to download after $max_retries attempts" "error"
        return 1
    fi

    if [ ! -s "$output_file" ]; then
        log_message "Downloaded file is empty" "error"
        return 1
    fi

    log_message "Extracting to $extract_dir" "running"
    mkdir -p "$extract_dir"

    case $file_type in
        "zip")
            unzip -qq -o "$output_file" -d "$extract_dir" || {
                log_message "Failed to extract zip file" "error"
                return 1
            }
            ;;
        "tar.gz")
            tar -xzf "$output_file" -C "$extract_dir" || {
                log_message "Failed to extract tar.gz file" "error"
                return 1
            }
            ;;
    esac

    return 0
}

# Centralized version checking
check_version() {
    local addon="$1"
    local current="${2:-none}"
    local new="$3"

    if [ "$current" != "$new" ]; then
        log_message "New version of $addon available: $new (current: $current)" "running"
        return 0
    fi

    log_message "No new version of $addon available. Current: $current" "running"
    return 1
}

cleanup_and_update() {
    if [ "${CLEANUP_ENABLED:-0}" = "1" ]; then
        cleanup
    fi

    mkdir -p "$TEMP_DIR"

    if [ "${MS_AUTOUPDATE:-0}" = "1" ] || ([ ! -d "$MODSHARP_DIR" ]); then
        update_modsharp
    fi

    # Clean up
    rm -rf "$TEMP_DIR"
}

update_addon() {
    local repo="$1"
    local output_path="$2"
    local temp_subdir="$3"
    local addon_name="$4"
    local temp_dir="$TEMP_DIR/$temp_subdir"

    mkdir -p "$output_path" "$temp_dir"
    rm -rf "$temp_dir"/*

    local api_response=$(curl -s "https://api.github.com/repos/$repo/releases/latest")
    if [ -z "$api_response" ]; then
        log_message "Failed to get release info for $repo" "error"
        return 1
    fi

    local new_version=$(echo "$api_response" | grep -oP '"tag_name": "\K[^"]+')
    local current_version=$(get_current_version "$addon_name")
    local asset_url=$(echo "$api_response" | grep -oP '"browser_download_url": "\K[^"]+-with-runtime-linux-[^"]+\.zip')

    if ! check_version "$addon_name" "$current_version" "$new_version"; then
        return 0
    fi

    if [ -z "$asset_url" ]; then
        log_message "No suitable asset found for $repo" "error"
        return 1
    fi

    if handle_download_and_extract "$asset_url" "$temp_dir/download.zip" "$temp_dir" "zip"; then
        cp -r "$temp_dir/addons/." "$output_path" && \
        update_version_file "$addon_name" "$new_version" && \
        log_message "Update of $repo completed successfully" "success"
        return 0
    fi

    return 1
}

get_latest_dotnet_version() {
    local requested_version="${DOTNET_VERSION:-9}"
    
    # If it's already a full version (e.g., "9.0.0"), use it as-is
    if [[ "$requested_version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$requested_version"
        return 0
    fi
    
    # If it's a major version (e.g., "9"), fetch the latest patch version
    log_message "Fetching latest .NET $requested_version runtime version..." "running"
    
    # Query Microsoft's official releases API for the latest version
    local releases_response=$(curl -s "https://api.github.com/repos/dotnet/core/releases" 2>/dev/null)
    if [ -n "$releases_response" ]; then
        # Look for the latest release that starts with the requested major version
        local latest_version=$(echo "$releases_response" | jq -r --arg major "$requested_version" '.[] | select(.tag_name | startswith("v" + $major + ".")) | .tag_name' | head -1 | sed 's/^v//')
        if [ -n "$latest_version" ]; then
            log_message "Found latest .NET $requested_version version: $latest_version" "running"
            echo "$latest_version"
            return 0
        fi
    fi
    
    # Alternative: try Microsoft's releases JSON API
    local alt_response=$(curl -s "https://dotnetcli.azureedge.net/dotnet/release-metadata/releases-index.json" 2>/dev/null)
    if [ -n "$alt_response" ]; then
        local latest_version=$(echo "$alt_response" | jq -r --arg major "$requested_version" '.releases-index[] | select(.["channel-version"] | startswith($major + ".")) | .["latest-release"]' | head -1)
        if [ -n "$latest_version" ]; then
            log_message "Found latest .NET $requested_version version: $latest_version" "running"
            echo "$latest_version"
            return 0
        fi
    fi
    
    # Fallback: construct a reasonable default
    case "$requested_version" in
        "9") echo "9.0.9" ;;
        *) echo "$requested_version.0.0" ;;
    esac
}

install_dotnet_runtime() {
    local runtime_dir="$MODSHARP_DIR/runtime"
    local dotnet_version=$(get_latest_dotnet_version)
    local current_dotnet_version=$(get_current_version "DotNet")
    
    # Check if we need to update .NET runtime
    if [ "$current_dotnet_version" = "$dotnet_version" ]; then
        log_message ".NET runtime already up to date: $dotnet_version" "running"
        return 0
    fi
    
    log_message "Installing .NET $dotnet_version runtime for ModSharp..." "running"
    
    # Create runtime directory
    mkdir -p "$runtime_dir"
    
    # Download and extract .NET runtime
    local dotnet_url="https://dotnetcli.azureedge.net/dotnet/Runtime/$dotnet_version/dotnet-runtime-$dotnet_version-linux-x64.tar.gz"
    
    if handle_download_and_extract "$dotnet_url" "$TEMP_DIR/dotnet-runtime.tar.gz" "$runtime_dir" "tar.gz"; then
        update_version_file "DotNet" "$dotnet_version"
        log_message ".NET $dotnet_version runtime installed successfully" "success"
        return 0
    else
        log_message "Failed to install .NET $dotnet_version runtime" "error"
        return 1
    fi
}

update_modsharp() {
    if [ ! -d "$MODSHARP_DIR" ]; then
        log_message "ModSharp not installed. Installing ModSharp..." "running"
    fi

    # Install .NET 9 runtime first
    if ! install_dotnet_runtime; then
        log_message "Failed to install .NET runtime, skipping ModSharp installation" "error"
        return 1
    fi

    # Get latest successful workflow run from GitHub Actions
    local workflow_runs_response=$(curl -s "https://api.github.com/repos/Kxnrl/modsharp-public/actions/workflows/master.yml/runs?status=completed&per_page=50")
    if [ -z "$workflow_runs_response" ]; then
        log_message "Failed to get ModSharp workflow runs" "error"
        return 1
    fi

    # Find the first workflow run with conclusion "success"
    local run_id=$(echo "$workflow_runs_response" | jq -r '.workflow_runs[] | select(.conclusion == "success") | .id' | head -1)
    local commit_sha=$(echo "$workflow_runs_response" | jq -r '.workflow_runs[] | select(.conclusion == "success") | .head_sha' | head -1)
    local run_date=$(echo "$workflow_runs_response" | jq -r '.workflow_runs[] | select(.conclusion == "success") | .created_at' | head -1)
    
    if [ -z "$run_id" ] || [ -z "$commit_sha" ]; then
        log_message "Failed to get valid workflow run information" "error"
        return 1
    fi

    # Use commit SHA (first 7 chars) + date as version identifier
    local new_version="git-${commit_sha:0:7}-$(date -d "$run_date" +%Y%m%d 2>/dev/null || echo "unknown")"
    local current_version=$(get_current_version "ModSharp")
    
    log_message "Current ModSharp version: ${current_version:-none}" "running"
    log_message "Available ModSharp version: $new_version" "running"
    
    # Check if we already have this version
    if [ "$current_version" = "$new_version" ]; then
        log_message "ModSharp is already up to date: $new_version" "running"
        return 0
    fi
    
    log_message "New ModSharp version available: $new_version (current: ${current_version:-none})" "running"

    # Get artifacts for this workflow run
    log_message "Fetching artifacts from workflow run $run_id..." "running"
    local artifacts_response=$(curl -s "https://api.github.com/repos/Kxnrl/modsharp-public/actions/runs/$run_id/artifacts")
    if [ -z "$artifacts_response" ]; then
        log_message "Failed to get ModSharp artifacts - empty response" "error"
        return 1
    fi
    
    # Check if response contains error
    local error_message=$(echo "$artifacts_response" | jq -r '.message // empty' 2>/dev/null)
    if [ -n "$error_message" ]; then
        log_message "GitHub API error: $error_message" "error"
        return 1
    fi

    # Debug: Show available artifacts
    log_message "Available artifacts:" "running"
    echo "$artifacts_response" | jq -r '.artifacts[]? | .name // "No artifacts found"' | while read -r artifact_name; do
        log_message "  - $artifact_name" "running"
    done

    # Find both Linux and Extensions artifacts
    local linux_artifact_url=$(echo "$artifacts_response" | jq -r '.artifacts[] | select(.name | test("ModSharp-git.*-linux")) | .archive_download_url // empty' | head -1)
    local linux_artifact_name=$(echo "$artifacts_response" | jq -r '.artifacts[] | select(.name | test("ModSharp-git.*-linux")) | .name // empty' | head -1)
    local extensions_artifact_url=$(echo "$artifacts_response" | jq -r '.artifacts[] | select(.name | test("ModSharp-git.*-extensions")) | .archive_download_url // empty' | head -1)
    local extensions_artifact_name=$(echo "$artifacts_response" | jq -r '.artifacts[] | select(.name | test("ModSharp-git.*-extensions")) | .name // empty' | head -1)
    
    if [ -z "$linux_artifact_url" ]; then
        log_message "No Linux ModSharp artifact found in workflow run $run_id" "error"
        return 1
    fi

    log_message "Found ModSharp Linux artifact: $linux_artifact_name" "running"
    if [ -n "$extensions_artifact_url" ]; then
        log_message "Found ModSharp Extensions artifact: $extensions_artifact_name" "running"
    else
        log_message "Warning: No Extensions artifact found - extensions will not be installed" "warn"
    fi

    # GitHub requires authentication for artifact downloads, even for public repos
    if [ -z "${GITHUB_TOKEN:-}" ]; then
        log_message "GITHUB_TOKEN is required for downloading ModSharp artifacts from GitHub Actions" "error"
        log_message "Please set the GITHUB_TOKEN environment variable with a valid GitHub personal access token" "error"
        return 1
    fi

    # Install Linux artifact (core files with config preservation)
    if ! install_modsharp_artifact "$linux_artifact_url" "Linux" "true"; then
        log_message "Failed to install ModSharp Linux artifact" "error"
        return 1
    fi

    # Install Extensions artifact if available (overlay on top)
    if [ -n "$extensions_artifact_url" ]; then
        if ! install_modsharp_artifact "$extensions_artifact_url" "Extensions" "false"; then
            log_message "Warning: Failed to install extensions, continuing anyway..." "warn"
        fi
    fi

    # Create required directories and update version
    create_modsharp_directories
    update_version_file "ModSharp" "$new_version"
    log_message "ModSharp update completed successfully" "success"
    return 0
}

update_modsharp_fallback() {
    log_message "Using fallback method: GitHub releases API" "running"
    
    # Get latest ModSharp release from GitHub releases as fallback
    local api_response=$(curl -s "https://api.github.com/repos/Kxnrl/modsharp-public/releases/latest")
    if [ -z "$api_response" ]; then
        log_message "Failed to get ModSharp release info from fallback method" "error"
        return 1
    fi

    local new_version=$(echo "$api_response" | jq -r '.tag_name // empty')
    local current_version=$(get_current_version "ModSharp")
    
    if [ -z "$new_version" ]; then
        log_message "Failed to extract version from release API" "error"
        return 1
    fi
    
    # Check if we already have this version
    if [ "$current_version" = "$new_version" ]; then
        log_message "ModSharp is already up to date: $new_version" "running"
        return 0
    fi
    
    log_message "New ModSharp version available: $new_version (current: ${current_version:-none})" "running"

    # Find the appropriate asset (looking for linux release)
    local asset_url=$(echo "$api_response" | jq -r '.assets[] | select(.name | test("ModSharp.*linux.*\\.zip"; "i")) | .browser_download_url // empty' | head -1)
    
    if [ -z "$asset_url" ]; then
        log_message "No suitable ModSharp Linux asset found in releases" "error"
        return 1
    fi

    if handle_download_and_extract "$asset_url" "$TEMP_DIR/modsharp-fallback.zip" "$TEMP_DIR/modsharp-fallback" "zip"; then
        # Create ModSharp directory if it doesn't exist
        mkdir -p "$MODSHARP_DIR"
        
        # Copy ModSharp files to the sharp directory
        if [ -d "$TEMP_DIR/modsharp-fallback/sharp" ]; then
            cp -rf "$TEMP_DIR/modsharp-fallback/sharp/." "$MODSHARP_DIR/" && \
            update_version_file "ModSharp" "$new_version" && \
            log_message "ModSharp fallback update completed successfully" "success"
        elif [ -d "$TEMP_DIR/modsharp-fallback" ]; then
            # If the zip contains files directly, copy them
            cp -rf "$TEMP_DIR/modsharp-fallback/." "$MODSHARP_DIR/" && \
            update_version_file "ModSharp" "$new_version" && \
            log_message "ModSharp fallback update completed successfully" "success"
        else
            log_message "ModSharp fallback archive structure not recognized" "error"
            return 1
        fi
        return 0
    fi

    return 1
}

configure_modsharp() {
    local GAMEINFO_FILE="/home/container/game/csgo/gameinfo.gi"
    local GAMEINFO_ENTRY="			Game	sharp"

    if [ -f "${GAMEINFO_FILE}" ]; then
        if ! grep -q "Game[[:blank:]]*sharp" "$GAMEINFO_FILE"; then # match any whitespace
            awk -v new_entry="$GAMEINFO_ENTRY" '
                BEGIN { found=0; }
                // {
                    if (found) {
                        print new_entry;
                        found=0;
                    }
                    print;
                }
                /Game_LowViolence/ { found=1; }
            ' "$GAMEINFO_FILE" > "$GAMEINFO_FILE.tmp" && mv "$GAMEINFO_FILE.tmp" "$GAMEINFO_FILE"
        fi
    fi
}