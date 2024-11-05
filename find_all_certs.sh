#!/bin/bash
#
# Finds all .pem certs on synology under /usr.
#
# Usage: ./find_all_certs.sh  [--valid-only | --invalid-only]
#   --valid-only     - Only show valid certificates found
#   --invalid-only   - Only show invalid certificates found
#   --no-color       - Don't display ANSII Color output

if [ "$EUID" -ne 0 ]; then
  echo "This script must be run as root or with sudo."
  exit 1
fi

# Color codes
GREEN="\033[1;32m"
RED="\033[0;31m"
YELLOW="\033[0;33m"
BLUE="\033[0;95m"
NC="\033[0m"  # No Color
BOLD="\033[1m"
HEAD_COL="\033[0;97m\033[0;100m"

# Initialize variables
NOW_TS=$(date +%s)
BASE_DIR=/usr/
WARNINGS=()
PREV_DIR=""
valid_count=0
count=0
total_count=0
total_valid=0
total_invalid=0
total_dirs_no_valid=0
total_dirs=0
valid_status=
mode=all
color=1

main() {
    parse_args "$@"

    print_header
    while read -r cert; do
        cert_dir=$(dirname "$cert")
        cert_file=$(basename "$cert")

        if parse_cert_info "$cert"; then  # Sets vars: $from, $to, $subject, $issuer, $validity_color & $valid_status
            process_dir_change "$cert_dir" "$cert_file"
            ((count++))
            ((total_count++))

            check_filter "$valid_status" || continue
            print_cert_line "$validity_color" "$cert_file" "$from" "$to" "$subject" "$issuer" "$valid_status"
        fi
    done < <(find "$BASE_DIR" -type f -name "*.pem" -not -path "/volume*" 2>/dev/null)

    printf "$(get_line_format "\u2517" "\u2537" "\u251B")" | sed 's/ /━/g'
    print_summary
}

parse_args() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --no-color)
                color=0
                shift
                ;;
            --valid-only)
                mode=valid_only
                shift
                ;;
            --invalid-only)
                mode=invalid_only
                shift
                ;;
            *)
                echo "Usage: $0 [--valid-only | --invalid-only] [--no-color]"
                exit 1
                ;;
        esac
    done

    if [[ "$color" == "0" ]]; then
        GREEN=
        RED=
        YELLOW=
        BLUE=
        NC=
        BOLD=
        HEAD_COL=
     fi
}

get_line_format() {
    local start=$1
    local mid=$2
    local end=$3
    local color_line="${4:-}"
    local color_status="${5:-}"

    local line_format="__START__LINE_COLOR %-44s __MID__ STATUS_COLOR%-28s${NC}LINE_COLOR __MID__ \
STATUS_COLOR%-28s${NC}LINE_COLOR __MID__ %-20s __MID__ %-20s __MID__ STATUS_COLOR%-7s ${NC}__END__\n"
    line_format="${line_format//__START__/${start}}"
    line_format="${line_format//__MID__/${mid}}"
    line_format="${line_format//__END__/${end}}"

    line_format="${line_format//STATUS_COLOR/${color_status}}"
    line_format="${line_format//LINE_COLOR/${color_line}}"

    echo "$line_format"
}

# Skip files that are not valid certificates
check_valid_cert() {
    local cert=$1
    if [[ "$(head -n 1 "$cert")" != "-----BEGIN CERTIFICATE-----" ]]; then
        return 1
    fi
    return 0
}

# Execute filtering based on mode
check_filter() {
    local valid_status=$1
    if [[ "$mode" == "valid_only" && "$valid_status" != "active" ]]; then
        return 1
    elif [[ "$mode" == "invalid_only" && "$valid_status" == "active" ]]; then
        return 1
    fi
    return 0
}


print_cert_line() {
    printf "$(get_line_format "\u2503" "\u2502" "\u2503" "" "$1")" "$2" "$3" "$4" "$5" "$6" "$7"
}

print_dir_warn() {
    if [[ "${count:-0}" -ne 0 && "${valid_count:-0}" -eq 0 ]]; then
        WARNINGS+=("$(echo -e "${RED}${BOLD}[WARN] No Valid Certs in: ${NC}${RED}$1/${NC}")")
        ((total_dirs_no_valid++))
    fi
}

print_header() {
    printf "$(get_line_format "\u250F" "\u252F" "\u2513")" | sed 's/ /\xE2\x94\x81/g'
    printf "$(get_line_format "\u2503" "\u2502" "\u2503" "${HEAD_COL}")" "Filename" "Valid From" "Valid To" "Domain" "Issuer" "Status"
}

process_dir_change() {
    local cert_dir="$1"
    local cert_file="$2"

    if [[ "$cert_dir" == "$PREV_DIR" ]]; then
        return
    fi

    print_dir_warn "$PREV_DIR"
    ((total_dirs++))

    valid_count=0
    count=0
    PREV_DIR="$cert_dir"

    printf "$(get_line_format "\u2520" "\u2534" "\u2528")" | sed 's/ /─/g'
    printf "\u2503 ${BLUE}%-162s${NC} \u2503\n" "$cert_dir"
    printf "$(get_line_format "\u2520" "\u252C" "\u2528")" | sed 's/ /─/g'
}

print_summary() {
    local line_format="${HEAD_COL}\u2503 ${BOLD}%-28s${NC}${HEAD_COL} \u2502 %-4s \u2503${NC}\n"

    echo ""
    printf "%s\n" "${WARNINGS[@]}"
    echo ""
    echo -e "${HEAD_COL}${BOLD}=====           Summary           =====${NC}"
    printf "${HEAD_COL}\u250F%37s\u2513${NC}\n" | sed 's/ /\xE2\x94\x81/g'
    printf "$line_format" "Total Directories" "$total_dirs"
    printf "$line_format" "Total Certificates" "$total_count"
    printf "$line_format" "Total Dirs w/ no valid cert" "$total_dirs_no_valid"
    printf "$line_format" "Total Valid Certs" "$total_valid"
    printf "$line_format" "Total InValid Certs" "$total_invalid"
    printf "${HEAD_COL}\u2517%37s\u251B${NC}\n" | sed 's/ /\xE2\x94\x81/g'
}

# Parses info from a SSL cert, extracting domain, issuer and dates. Provides time validity and appropriate color for validity status.
parse_cert_info() {
    local cert="$1"
    local cert_info

    # Parse details from cert_info
    cert_info=$(openssl x509 -in "$cert" -noout -subject -issuer -startdate -enddate 2>/dev/null)
    if [[ $? -ne 0 ]]; then
        return 1
    fi
    subject=$(echo "$cert_info" | sed -n '/^subject=/s/.*[Cc][Nn][ ]*=[ ]*\([^,]*\).*/\1/p')
    issuer=$(echo "$cert_info" | sed -n '/^issuer=/s/.*[Oo][ ]*=[ ]*\([^,]*\).*/\1/p')
    from=$(echo "$cert_info" | sed -n 's/^notBefore=//p')
    to=$(echo "$cert_info" | sed -n 's/^notAfter=//p')

    # Convert dates to Unix timestamps for comparison
    local from_ts=$(date -d "$from" +%s)
    local to_ts=$(date -d "$to" +%s)

    # Determine validity of certs
    valid_status="invalid"
    if (( from_ts > NOW_TS )); then
        validity_color=$YELLOW  # Not reached
        valid_status="future"
        ((total_invalid++))
    elif (( to_ts < NOW_TS )); then
        validity_color=$RED  # Expired
        valid_status="expired"
        ((total_invalid++))
    else
        validity_color=$GREEN  # Current
        valid_status="active"
        ((valid_count++))
        ((total_valid++))
    fi

    return 0
}

### Run main program ###
main "$@"
