#!/bin/bash
#
# CheckSSR.sh
#
# Pull the Short Sale Restriction (SSR) lists from NASDAQ and NYSE, check them for your
# positions, and email one report covering both markets.
#
# Usage: CheckSSR.sh [options]
#   -m, --market LIST   Markets to check: nasdaq, nyse or all (default: from config, else all)
#   -d, --date YYYYMMDD Look for lists on or before this date (default: today)
#   -n, --top N         How many "most recently listed" stocks to show per market (default 10)
#   -p, --print         Print the report instead of emailing it (nothing is sent)
#   -h, --help          Show this help
#
# To automate - schedule launchd (Mac) to run weekdays at 8:40am CT (just after the 9:30am ET open)
#
# Changelog:
# 20210227 - Created.
# 20210306 - Changed wget to curl. Now sending hits as attachment
# 20210307 - Added pre-flight check
# 20210308 - Optional to send results in body or as attachment
# 20250514 - Updated for MacOS compatibility, improved error handling and security
# 20250522 - Added functionality to get a copy of the SSR list and report top 10 stocks
# 20261105 - Top 10 is now the 10 most recently listed (real date/time sort, newest first);
#            ticker matching uses the Symbol column only
# 20261112 - Added NYSE (NYSE, NYSE American, NYSE Arca) next to NASDAQ. One script, one
#            positions file and one email cover both markets. Each market has a small
#            fetch-and-normalize function; matching, top N and email are shared.
#            Uses the latest available list when today's does not exist (weekends, holidays).
#            Email is always sent in the body (attachment mode needed mpack, which Homebrew
#            does not have). Added --print, --date, --market and --top options.
#
# Where the lists come from:
#   NASDAQ  https://nasdaqtrader.com/dynamic/symdir/shorthalts/shorthaltsYYYYMMDD.txt
#           A text file that NASDAQ creates about 5am ET each day and updates during the day.
#           It holds the stocks restricted today: yesterday's triggers plus today's so far.
#   NYSE    ftp://ftp.nyxdata.com/NYSEGroupSSRCircuitBreakers/
#           One Excel (.xls) file per trading day covering NYSE, NYSE American and NYSE Arca.
#           It is published after the close (about 8:15pm CT) and holds only the stocks that
#           triggered that day. So in the morning the newest NYSE file is the previous
#           trading day's, which is exactly the set of NYSE stocks restricted today.
#   A stock that triggers is restricted for the rest of that day and all of the next day.
#   Not covered: other exchanges that list securities (for example Cboe BZX, mostly ETFs).
#
# Requires:
#   List of ticker symbols to look for (one ticker per line), used for every market
#   Configuration file with email settings
#   curl, awk, and msmtp or mail (to send email); python3 for NYSE (reads the .xls file)


############################################
# Script setup
############################################

# Enable strict mode
set -euo pipefail

# launchd and cron start jobs with a minimal PATH that leaves out Homebrew's folders, which is
# where msmtp and python3 usually live. Add them at the end so system tools still win.
PATH="${PATH}:/opt/homebrew/bin:/usr/local/bin"
export PATH

# Setup logging
SCRIPT_NAME=$(basename "$0")
LOG_DIR="${HOME}/Library/Logs/CheckSSR"
LOG_FILE="${LOG_DIR}/checkssr_$(date +%Y%m%d).log"

# Create log directory if it doesn't exist
mkdir -p "${LOG_DIR}"

# Remember where this run's lines start in the log (used in the failure email)
RUN_LOG_START=$(wc -l < "${LOG_FILE}" 2>/dev/null || echo 0)
FAILURE_MAILED=0

# Function to log messages: to the log file and the screen. With --print the report goes to
# stdout, so log lines go to stderr then; otherwise they go to stdout (launchd keeps its
# "error" log for real errors only).
log() {
    local level="$1"
    local message="$2"
    local line
    line="[$(date '+%Y-%m-%d %H:%M:%S')] [${level}] ${message}"
    if [[ "${PRINT_ONLY}" -eq 1 ]]; then
        echo "${line}" | tee -a "${LOG_FILE}" >&2
    else
        echo "${line}" | tee -a "${LOG_FILE}"
    fi
}

usage() {
    sed -n '/^# Usage:/,/^#   -h, --help/p' "$0" | sed 's/^# \{0,1\}//'
}

# Send a plain-text email to MAILTO.
# Uses msmtp when installed (authenticated SMTP, e.g. Gmail, configured in ~/.msmtprc),
# otherwise falls back to the system mail command, which often cannot deliver from a
# home network because outgoing port 25 is blocked.
send_mail() {
    local subject="$1"
    local body="$2"
    if command -v msmtp >/dev/null 2>&1; then
        printf 'To: %s\nSubject: %s\nContent-Type: text/plain; charset=UTF-8\n\n%s\n' \
            "${MAILTO}" "${subject}" "${body}" | msmtp "${MAILTO}"
    else
        printf '%s\n' "${body}" | mail -s "${subject}" "${MAILTO}"
    fi
}

# Runs whenever the script ends. If it ended with an error during an unattended run, email
# the details so a failure is never silent, then clean up the temporary files.
on_exit() {
    local rc=$?
    if [[ ${rc} -ne 0 && "${PRINT_ONLY}" -eq 0 && "${FAILURE_MAILED}" -eq 0 \
          && -n "${MAILTO}" && "${MAILTO}" != "your.email@example.com" ]]; then
        FAILURE_MAILED=1
        send_mail "SSR Check Failed" "CheckSSR failed on $(date '+%Y-%m-%d at %H:%M').

What the script logged:
$(tail -n +"$((RUN_LOG_START + 1))" "${LOG_FILE}" 2>/dev/null | tail -n 15)" || true
    fi
    log "INFO" "Cleaning up temporary files"
    rm -rf "${TEMPDIR}"
    log "INFO" "Script completed"
}

# Print the date N days before a YYYYMMDD date (works with both BSD/macOS and GNU date)
date_offset() {
    local base="$1" days="$2"
    if date -j -f %Y%m%d "${base}" +%Y%m%d >/dev/null 2>&1; then
        date -j -v-"${days}"d -f %Y%m%d "${base}" +%Y%m%d
    else
        date -d "${base} -${days} days" +%Y%m%d
    fi
}

# Command line options (applied after the configuration file is loaded)
PRINT_ONLY=0
OPT_MARKETS=""
OPT_DATE=""
OPT_TOP=""
while [[ $# -gt 0 ]]; do
    case "$1" in
        -m|--market) OPT_MARKETS="${2:-}"; shift 2 || true ;;
        -d|--date)   OPT_DATE="${2:-}";    shift 2 || true ;;
        -n|--top)    OPT_TOP="${2:-}";     shift 2 || true ;;
        -p|--print)  PRINT_ONLY=1; shift ;;
        -h|--help)   usage; exit 0 ;;
        *) echo "Unknown option: $1" >&2; usage >&2; exit 2 ;;
    esac
done

log "INFO" "Starting ${SCRIPT_NAME}"

# Configuration
CONFIG_DIR="${HOME}/.config/CheckSSR"
CONFIG_FILE="${CONFIG_DIR}/config.sh"

# Default configuration values
MAILTO=""                            # email to send notifications to
MARKETS="NASDAQ NYSE"                # which lists to check: NASDAQ and/or NYSE
TOPN=10                              # most recently listed stocks to show per market
SENDSTYLE=0                          # no longer used (attachments were removed)
STOCKS=""                            # positions file (defaults to ${CONFIG_DIR}/positions.txt)

# Load configuration if it exists
if [[ -f "${CONFIG_FILE}" ]]; then
    log "INFO" "Loading configuration from ${CONFIG_FILE}"
    # shellcheck source=/dev/null
    source "${CONFIG_FILE}"
else
    # Create default config if it doesn't exist
    log "WARN" "Configuration file not found, creating default at ${CONFIG_FILE}"
    mkdir -p "${CONFIG_DIR}"
    cat > "${CONFIG_FILE}" << EOL
# CheckSSR Configuration File
# Set your preferences below

# Email address to receive notifications
MAILTO="your.email@example.com"

# Path to your stock positions file (one ticker per line, used for every market).
# Keep it outside Documents and Desktop: iCloud can manage those folders, and scheduled
# (launchd) runs may then be unable to read the file.
STOCKS="${CONFIG_DIR}/positions.txt"

# Which SSR lists to check: NASDAQ, NYSE or both
MARKETS="NASDAQ NYSE"

# How many most recently listed stocks to show per market
TOPN=10
EOL
    log "ERROR" "Please edit ${CONFIG_FILE} to set your preferences then run again"
    exit 1
fi

# Command line options override the configuration file
[[ -n "${OPT_MARKETS}" ]] && MARKETS="${OPT_MARKETS}"
[[ -n "${OPT_TOP}" ]] && TOPN="${OPT_TOP}"
STOCKS="${STOCKS:-${CONFIG_DIR}/positions.txt}"

# Validate configuration
if [[ "${PRINT_ONLY}" -eq 0 ]] && [[ -z "${MAILTO}" || "${MAILTO}" == "your.email@example.com" ]]; then
    log "ERROR" "Email address not configured. Please edit ${CONFIG_FILE}"
    exit 1
fi
if [[ "${SENDSTYLE}" -eq 1 ]]; then
    log "WARN" "SENDSTYLE=1 (attachments) is no longer supported; the report is sent in the email body"
fi
if ! [[ "${TOPN}" =~ ^[0-9]+$ ]] || [[ "${TOPN}" -lt 1 ]]; then
    log "ERROR" "TOPN must be a positive number (got '${TOPN}')"
    exit 1
fi

# Turn the markets setting into a clean list: all/both -> NASDAQ NYSE, upper-case, no repeats
MARKET_LIST=""
for m in $(echo "${MARKETS}" | tr ',[:lower:]' ' [:upper:]'); do
    case "${m}" in
        ALL|BOTH) MARKET_LIST="NASDAQ NYSE"; break ;;
        NASDAQ|NYSE) case " ${MARKET_LIST} " in *" ${m} "*) ;; *) MARKET_LIST="${MARKET_LIST:+${MARKET_LIST} }${m}" ;; esac ;;
        *) log "ERROR" "Unknown market '${m}'. Use NASDAQ, NYSE or ALL."; exit 1 ;;
    esac
done
if [[ -z "${MARKET_LIST}" ]]; then
    log "ERROR" "No markets selected"
    exit 1
fi


# ----------------------------------------------- #
# -------------- SCRIPT VARIABLES -------------- #
# ----------------------------------------------- #

# The date lists are looked up for (today unless --date was given)
TODAY="${OPT_DATE:-$(date +%Y%m%d)}"
if ! [[ "${TODAY}" =~ ^[0-9]{8}$ ]]; then
    log "ERROR" "--date must look like YYYYMMDD (got '${TODAY}')"
    exit 1
fi
LOOKBACK_DAYS=10   # how far back to look for the latest list (weekends, holidays)

NASDAQ_MAINURL="https://www.nasdaqtrader.com/trader.aspx?id=ShortSaleCircuitBreaker"
NASDAQ_FILEBASE="https://www.nasdaqtrader.com/dynamic/symdir/shorthalts"
NYSE_FILEBASE="ftp://ftp.nyxdata.com/NYSEGroupSSRCircuitBreakers"

TEMPDIR=""
ALL_PATH=""
HITS_PATH=""
FAILED_NOTES=""     # one line per market that could not be retrieved

# Create secure temporary files with predictable cleanup
setup_temp_files() {
    TEMPDIR=$(mktemp -d "${TMPDIR:-/tmp}/ssr_check.XXXXXXXX") || {
        log "ERROR" "Failed to create temporary directory"
        exit 1
    }
    ALL_PATH="${TEMPDIR}/all_markets.tsv"   # every market's list in the common format
    HITS_PATH="${TEMPDIR}/hits.tsv"         # rows that match your positions

    # Setup trap to remove temporary files on exit
    trap on_exit EXIT
    log "INFO" "Temporary files set up in ${TEMPDIR}"
}

# Your tickers, one per line: comments and blanks removed, upper-cased
positions_list() {
    awk '{ gsub(/[ \t\r]/, ""); if ($0 != "" && $0 !~ /^#/) print toupper($0) }' "${STOCKS}"
}

preflight_check() {
    log "INFO" "Running preflight checks"

    # Check if running as root (unnecessary on personal machines but kept for safety)
    if [[ $UID -eq 0 ]]; then
        log "ERROR" "Script should not be run as root"
        exit 1
    fi

    # Check for required commands
    local cmd
    for cmd in curl awk sort; do
        if ! command -v "${cmd}" &> /dev/null; then
            log "ERROR" "${cmd} is required but not found. Install it with your package manager."
            exit 1
        fi
    done
    if [[ "${PRINT_ONLY}" -eq 0 ]] && ! command -v msmtp &> /dev/null && ! command -v mail &> /dev/null; then
        log "ERROR" "Neither msmtp nor mail was found, so the report cannot be emailed"
        log "ERROR" "Install msmtp (recommended) or use --print to show the report instead"
        exit 1
    fi
    # The NYSE list is an Excel file, which is read with python3 (standard library only)
    case " ${MARKET_LIST} " in
        *" NYSE "*)
            if ! command -v python3 &> /dev/null || ! python3 -c 'import struct' &> /dev/null; then
                log "ERROR" "python3 is required to read the NYSE list but is not working"
                log "ERROR" "Install Python 3 (python.org or your package manager), or use --market nasdaq"
                exit 1
            fi
            ;;
    esac

    # Documents and Desktop can be managed by iCloud, and background jobs (launchd) cannot
    # always read files there ("Resource deadlock avoided"), which makes scheduled runs fail.
    case "${STOCKS}" in
        "${HOME}/Documents/"*|"${HOME}/Desktop/"*)
            log "WARN" "The positions file is in Documents or Desktop, which iCloud may manage."
            log "WARN" "Scheduled runs can fail to read it. Consider moving it to ${CONFIG_DIR}/positions.txt"
            ;;
    esac

    # Check for ticker list
    if [[ ! -f "${STOCKS}" ]]; then
        log "ERROR" "Stock positions file not found: ${STOCKS}"
        log "INFO" "Creating sample positions file"

        mkdir -p "$(dirname "${STOCKS}")"
        cat > "${STOCKS}" << EOL
# Add one ticker symbol per line (lines starting with # are ignored).
# The same list is checked against every market (NASDAQ and NYSE).
# Example - remove the leading # to activate:
# AAPL
# MSFT
# BRK.B
EOL
        log "ERROR" "Please edit ${STOCKS} with your positions and run again"
        exit 1
    fi

    # Make sure the file can actually be read, so a read error is not reported as "no tickers"
    if ! cat "${STOCKS}" > /dev/null 2> "${TEMPDIR}/read_error.txt"; then
        log "ERROR" "Cannot read the positions file ${STOCKS}: $(cat "${TEMPDIR}/read_error.txt")"
        exit 1
    fi

    # Validate positions file content: at least one ticker, and only valid characters
    local tickers bad
    tickers=$(positions_list | wc -l | tr -d ' ')
    if [[ "${tickers}" -eq 0 ]]; then
        log "ERROR" "Stock positions file has no tickers: ${STOCKS}"
        log "ERROR" "Add one ticker symbol per line (lines starting with # are ignored)"
        exit 1
    fi
    bad=$(positions_list | awk '$0 !~ /^[A-Z0-9.-]+$/')
    if [[ -n "${bad}" ]]; then
        log "ERROR" "Stock positions file contains invalid ticker symbols: $(echo "${bad}" | tr '\n' ' ')"
        log "ERROR" "Each line should contain a single valid ticker symbol (letters, numbers, dots or hyphens)"
        exit 1
    fi

    log "INFO" "Preflight checks passed (${tickers} tickers, markets: ${MARKET_LIST})"
}


####################################################
# Markets
#
# Each market has a fetch function that finds the latest available list and writes it in
# one common format, a tab-separated file with these columns:
#   source <tab> symbol <tab> security name <tab> listed on <tab> trigger time (YYYY-MM-DD HH:MM:SS, Eastern)
# Everything after that (matching, top N, the email) works on this common format, so adding
# another market means writing one more fetch function.
####################################################

# --- NASDAQ: CSV text file, columns Symbol,Security Name,Market Category,Trigger Time ---
# Names that contain commas are quoted. The file ends with a footer line holding a
# file-creation timestamp, which is skipped because it has no valid trigger time.
normalize_nasdaq() {
    tr -d '\r' < "$1" | awk -F, '
        NR == 1 { next }
        {
            n = split($0, f, ",")
            t = f[n]
            if (n < 4 || t !~ /^[0-9]+\/[0-9]+\/[0-9][0-9][0-9][0-9] [0-9]+:[0-9][0-9]:[0-9][0-9] [AP]M$/) next
            name = f[2]
            for (i = 3; i <= n - 2; i++) name = name "," f[i]
            gsub(/^"|"$/, "", name)
            gsub(/^ +| +$/, "", name); gsub(/  +/, " ", name)
            split(t, dt, " "); split(dt[1], d, "/"); split(dt[2], tm, ":")
            h = tm[1] % 12; if (dt[3] == "PM") h += 12
            printf "NASDAQ\t%s\t%s\tNASDAQ\t%04d-%02d-%02d %02d:%02d:%02d\n", f[1], name, d[3], d[1], d[2], h, tm[2], tm[3]
        }'
}

fetch_nasdaq() {
    local raw="${TEMPDIR}/nasdaq_raw.txt" i d
    log "INFO" "Retrieving SSR list from NASDAQ"

    # First request to handle the SAMEORIGIN requirement
    if ! curl --max-time 30 --retry 3 --silent --fail --location "${NASDAQ_MAINURL}" > /dev/null 2>&1; then
        log "WARN" "Initial request to NASDAQ failed, trying anyway"
    fi

    for ((i = 0; i <= LOOKBACK_DAYS; i++)); do
        d=$(date_offset "${TODAY}" "${i}")
        if curl --max-time 30 --retry 3 --silent --fail --location \
                "${NASDAQ_FILEBASE}/shorthalts${d}.txt" -o "${raw}" 2>/dev/null && [[ -s "${raw}" ]]; then
            if grep -q "SAMEORIGIN" "${raw}"; then
                log "ERROR" "Received SAMEORIGIN error, possibly rate-limited by NASDAQ"
                FAILED_NOTES+="NASDAQ: rate limited by the NASDAQ site"$'\n'
                return 1
            fi
            # A real list starts with a "Symbol,..." header; anything else is an error page
            if awk 'NR == 1 { exit ($0 ~ /^Symbol,/ ? 0 : 1) }' "${raw}"; then
                normalize_nasdaq "${raw}" > "${TEMPDIR}/nasdaq.tsv"
                NASDAQ_FILEDATE="${d}"
                NASDAQ_AGE="${i}"
                NASDAQ_ROWS=$(wc -l < "${TEMPDIR}/nasdaq.tsv" | tr -d ' ')
                log "INFO" "NASDAQ list for ${d}: ${NASDAQ_ROWS} stocks"
                return 0
            fi
        fi
        log "DEBUG" "No NASDAQ list for ${d}"
    done
    log "ERROR" "Could not find a NASDAQ list in the last ${LOOKBACK_DAYS} days"
    FAILED_NOTES+="NASDAQ: no list found in the last ${LOOKBACK_DAYS} days"$'\n'
    return 1
}

# --- NYSE: Excel file with columns Trigger Date, Issue Symbol, Issue Name, Primary Exchange,
#     SSR State, Trigger Time, Anticipated Deactivation Date. Primary Exchange is NYSE,
#     MKT (NYSE American) or P (NYSE Arca). ---
normalize_nyse() {
    awk -F'\t' '
        NR == 1 { next }
        $1 ~ /^[0-9]+\/[0-9]+\/[0-9][0-9][0-9][0-9]$/ && $6 ~ /^[0-9]+:[0-9][0-9]:[0-9][0-9]$/ {
            split($1, d, "/"); split($6, tm, ":")
            ex = $4
            if (ex == "MKT") ex = "NYSE American"; else if (ex == "P") ex = "NYSE Arca"
            printf "NYSE\t%s\t%s\t%s\t%04d-%02d-%02d %02d:%02d:%02d\n", $2, $3, ex, d[3], d[1], d[2], tm[1], tm[2], tm[3]
        }' "$1"
}

fetch_nyse() {
    local xls tsv i d
    log "INFO" "Retrieving SSR list from NYSE"

    # The newest file is published after the close, so today's usually does not exist yet
    # in the morning; the latest available one is used instead.
    for ((i = 0; i <= LOOKBACK_DAYS; i++)); do
        d=$(date_offset "${TODAY}" "${i}")
        xls="${TEMPDIR}/nyse_${d}.xls"
        if curl --max-time 60 --retry 2 --silent --fail \
                "${NYSE_FILEBASE}/NYSEGroupSSRCircuitBreakers_${d:0:4}/NYSEGroupSSRCircuitBreakers_${d:0:6}/NYSEGroupSSRCircuitBreakers${d}.xls" \
                -o "${xls}" 2>/dev/null && [[ -s "${xls}" ]]; then
            tsv="${TEMPDIR}/nyse_raw.tsv"
            if ! xls_to_tsv "${xls}" > "${tsv}" 2> "${TEMPDIR}/xls_error.txt"; then
                log "ERROR" "Could not read the NYSE file for ${d}: $(cat "${TEMPDIR}/xls_error.txt")"
                FAILED_NOTES+="NYSE: could not read the file for ${d}"$'\n'
                return 1
            fi
            normalize_nyse "${tsv}" > "${TEMPDIR}/nyse.tsv"
            NYSE_FILEDATE="${d}"
            NYSE_AGE="${i}"
            NYSE_ROWS=$(wc -l < "${TEMPDIR}/nyse.tsv" | tr -d ' ')
            log "INFO" "NYSE list for ${d}: ${NYSE_ROWS} stocks"
            return 0
        fi
        log "DEBUG" "No NYSE list for ${d}"
    done
    log "ERROR" "Could not find an NYSE list in the last ${LOOKBACK_DAYS} days"
    FAILED_NOTES+="NYSE: no list found in the last ${LOOKBACK_DAYS} days"$'\n'
    return 1
}

# Fetch every selected market; one failing does not stop the others
fetch_markets() {
    local m ok=0
    : > "${ALL_PATH}"
    for m in ${MARKET_LIST}; do
        case "${m}" in
            NASDAQ) fetch_nasdaq && { cat "${TEMPDIR}/nasdaq.tsv" >> "${ALL_PATH}"; ok=$((ok + 1)); } || true ;;
            NYSE)   fetch_nyse   && { cat "${TEMPDIR}/nyse.tsv"   >> "${ALL_PATH}"; ok=$((ok + 1)); } || true ;;
        esac
    done
    if [[ "${ok}" -eq 0 ]]; then
        log "ERROR" "No SSR list could be retrieved"
        if [[ "${PRINT_ONLY}" -eq 0 ]]; then
            FAILURE_MAILED=1
            send_mail "SSR Check Failed" "Could not retrieve any SSR list for ${TODAY}:
${FAILED_NOTES}" || true
        fi
        exit 1
    fi
}

# Per-market results, filled in by the fetch functions
NASDAQ_FILEDATE=""; NASDAQ_AGE=0; NASDAQ_ROWS=0
NYSE_FILEDATE="";   NYSE_AGE=0;   NYSE_ROWS=0

####################################################
# Embedded helper: convert the first sheet of an old Excel (.xls) file to tab-separated
# text. The NYSE list is published as .xls and bash cannot read that, so this small
# python3 program (standard library only, no pip packages) does it. Keeping it inside
# this script means there is still just one file to install.
####################################################
xls_to_tsv() {
    python3 - "$1" <<'PYEOF'
"""Convert the first worksheet of a legacy Excel (.xls, BIFF8) file to tab-separated text.

Standard library only. Handles what plain data sheets contain: text, numbers, blanks.
Usage: xls2tsv.py FILE.xls > FILE.tsv
"""
import struct
import sys

ENDOFCHAIN = 0xFFFFFFFE
FREESECT = 0xFFFFFFFF


def read_ole_stream(data, names=("Workbook", "Book")):
    """Return the bytes of the Workbook stream inside an OLE2 (Compound File) container."""
    if data[:8] != b"\xd0\xcf\x11\xe0\xa1\xb1\x1a\xe1":
        raise ValueError("not an .xls (OLE2) file")
    sec_size = 1 << struct.unpack_from("<H", data, 30)[0]
    mini_size = 1 << struct.unpack_from("<H", data, 32)[0]
    dir_start = struct.unpack_from("<I", data, 48)[0]
    cutoff = struct.unpack_from("<I", data, 56)[0]
    minifat_start = struct.unpack_from("<I", data, 60)[0]
    difat_start = struct.unpack_from("<I", data, 68)[0]
    n_difat = struct.unpack_from("<I", data, 72)[0]

    def sector(sid):
        off = (sid + 1) * sec_size
        return data[off:off + sec_size]

    # Sector ids of the FAT, from the header DIFAT and any extra DIFAT sectors
    difat = list(struct.unpack_from("<109I", data, 76))
    sid = difat_start
    for _ in range(n_difat):
        if sid in (ENDOFCHAIN, FREESECT):
            break
        chunk = sector(sid)
        ids = struct.unpack_from("<%dI" % (sec_size // 4), chunk)
        difat.extend(ids[:-1])
        sid = ids[-1]
    fat = []
    for fsid in difat:
        if fsid in (ENDOFCHAIN, FREESECT):
            continue
        fat.extend(struct.unpack_from("<%dI" % (sec_size // 4), sector(fsid)))

    def chain(start, table):
        out, seen = [], set()
        while start not in (ENDOFCHAIN, FREESECT) and start < len(table) and start not in seen:
            seen.add(start)
            out.append(start)
            start = table[start]
        return out

    def read_chain(start):
        return b"".join(sector(s) for s in chain(start, fat))

    directory = read_chain(dir_start)
    entries = []
    for i in range(0, len(directory), 128):
        e = directory[i:i + 128]
        if len(e) < 128:
            break
        name_len = struct.unpack_from("<H", e, 64)[0]
        name = e[:max(name_len - 2, 0)].decode("utf-16le", "replace")
        etype = e[66]
        start = struct.unpack_from("<I", e, 116)[0]
        size = struct.unpack_from("<I", e, 120)[0]
        entries.append((name, etype, start, size))

    root = entries[0]
    for name, etype, start, size in entries:
        if etype == 2 and name in names:
            if size >= cutoff:
                return read_chain(start)[:size]
            ministream = read_chain(root[2])[:root[3]]
            minifat = []
            for msid in chain(minifat_start, fat):
                minifat.extend(struct.unpack_from("<%dI" % (sec_size // 4), sector(msid)))
            parts = [ministream[m * mini_size:(m + 1) * mini_size] for m in chain(start, minifat)]
            return b"".join(parts)[:size]
    raise ValueError("no Workbook stream found")


def records(stream, pos=0):
    """Yield (record id, body) from a BIFF record stream."""
    while pos + 4 <= len(stream):
        rid, ln = struct.unpack_from("<HH", stream, pos)
        yield pos, rid, stream[pos + 4:pos + 4 + ln]
        pos += 4 + ln


class SstReader:
    """Reads the shared string table, which can continue across CONTINUE records."""

    def __init__(self, segments):
        self.segs = segments
        self.si = 0
        self.buf = segments[0]
        self.p = 8  # skip total/unique counts

    def _next(self):
        self.si += 1
        if self.si >= len(self.segs):
            raise EOFError
        self.buf, self.p = self.segs[self.si], 0

    def take(self, n):
        out = b""
        while n > 0:
            if self.p >= len(self.buf):
                self._next()
            chunk = self.buf[self.p:self.p + n]
            self.p += len(chunk)
            n -= len(chunk)
            out += chunk
        return out

    def string(self):
        cch = struct.unpack("<H", self.take(2))[0]
        flags = self.take(1)[0]
        wide = bool(flags & 1)
        runs = struct.unpack("<H", self.take(2))[0] if flags & 8 else 0
        ext = struct.unpack("<I", self.take(4))[0] if flags & 4 else 0
        text, remaining = [], cch
        while remaining > 0:
            if self.p >= len(self.buf):
                self._next()
                wide = bool(self.buf[0] & 1)  # a continued string restates its width
                self.p = 1
            width = 2 if wide else 1
            n = min(remaining, (len(self.buf) - self.p) // width)
            if n == 0:
                self._next()
                wide = bool(self.buf[0] & 1)
                self.p = 1
                continue
            raw = self.buf[self.p:self.p + n * width]
            text.append(raw.decode("utf-16le" if wide else "latin-1", "replace"))
            self.p += n * width
            remaining -= n
        if runs:
            self.take(4 * runs)
        if ext:
            self.take(ext)
        return "".join(text)


def decode_rk(v):
    if v & 2:
        n = struct.unpack("<i", struct.pack("<I", v))[0] >> 2
    else:
        n = struct.unpack("<d", struct.pack("<Q", (v & 0xFFFFFFFC) << 32))[0]
    return n / 100.0 if v & 1 else n


def fmt_number(n):
    return str(int(n)) if float(n).is_integer() else repr(float(n))


def clean(s):
    return " ".join(s.replace("\t", " ").replace("\r", " ").replace("\n", " ").split())


def first_sheet_rows(stream):
    # Workbook globals: shared strings and the offset of the first worksheet
    sst_segments, sheet_offset = None, None
    last = None
    for pos, rid, body in records(stream):
        if rid == 0x00FC:
            sst_segments, last = [body], "sst"
        elif rid == 0x003C and last == "sst":
            sst_segments.append(body)
        else:
            if rid != 0x003C:
                last = None
            if rid == 0x0085 and sheet_offset is None and len(body) > 5 and body[5] == 0:
                sheet_offset = struct.unpack_from("<I", body, 0)[0]
        if rid == 0x000A:  # end of globals
            break
    if sheet_offset is None:
        raise ValueError("no worksheet found")
    strings = []
    if sst_segments:
        reader = SstReader(sst_segments)
        total = struct.unpack_from("<I", sst_segments[0], 4)[0]
        try:
            for _ in range(total):
                strings.append(reader.string())
        except EOFError:
            pass

    cells, depth = {}, 0
    for pos, rid, body in records(stream, sheet_offset):
        if rid == 0x0809:
            depth += 1
        elif rid == 0x000A:
            depth -= 1
            if depth <= 0:
                break
        elif depth == 1:
            if rid == 0x00FD:  # LABELSST
                r, c, _, idx = struct.unpack_from("<HHHI", body)
                cells[(r, c)] = strings[idx] if idx < len(strings) else ""
            elif rid == 0x0204:  # LABEL (inline text)
                r, c, _, cch = struct.unpack_from("<HHHH", body)
                flags = body[8]
                raw = body[9:9 + cch * (2 if flags & 1 else 1)]
                cells[(r, c)] = raw.decode("utf-16le" if flags & 1 else "latin-1", "replace")
            elif rid == 0x0203:  # NUMBER
                r, c, _ = struct.unpack_from("<HHH", body)
                cells[(r, c)] = fmt_number(struct.unpack_from("<d", body, 6)[0])
            elif rid == 0x027E:  # RK
                r, c, _, v = struct.unpack_from("<HHHI", body)
                cells[(r, c)] = fmt_number(decode_rk(v))
            elif rid == 0x00BD:  # MULRK
                r, c1 = struct.unpack_from("<HH", body)
                c2 = struct.unpack_from("<H", body, len(body) - 2)[0]
                for i, c in enumerate(range(c1, c2 + 1)):
                    v = struct.unpack_from("<I", body, 4 + 6 * i + 2)[0]
                    cells[(r, c)] = fmt_number(decode_rk(v))
    return cells


def main(path):
    with open(path, "rb") as f:
        data = f.read()
    cells = first_sheet_rows(read_ole_stream(data))
    if not cells:
        return
    max_row = max(r for r, _ in cells)
    max_col = max(c for _, c in cells)
    out = sys.stdout
    for r in range(max_row + 1):
        row = [clean(cells.get((r, c), "")) for c in range(max_col + 1)]
        out.write("\t".join(row) + "\n")


if __name__ == "__main__":
    if len(sys.argv) != 2:
        sys.exit("usage: xls2tsv.py FILE.xls")
    try:
        main(sys.argv[1])
    except Exception as exc:  # report cleanly so the calling script can react
        sys.exit("xls2tsv: %s" % exc)
PYEOF
}


####################################################
# Shared logic: works on the common format, for every market
####################################################

# Find your positions in the lists. Spaces, dots, slashes and hyphens count as the same
# character, because NYSE writes class shares as "BH A" and preferreds as "ABR PRD" while
# you would write BH.A and ABR.PRD. Only the Symbol column is compared, never the name.
search() {
    log "INFO" "Searching for positions in the SSR lists"
    positions_list > "${TEMPDIR}/positions.txt"

    awk -F'\t' '
        function norm(s) { s = toupper(s); gsub(/[ .\/-]/, ".", s); return s }
        FNR == NR { want[norm($0)] = 1; next }
        norm($2) in want { print }
    ' "${TEMPDIR}/positions.txt" "${ALL_PATH}" | sort -t "$(printf '\t')" -k2,2 -k5,5r > "${HITS_PATH}"

    local src sym
    while IFS=$'\t' read -r src sym; do
        log "INFO" "Found match for ${sym} on ${src} list"
    done < <(awk -F'\t' '{ print $1 "\t" $2 }' "${HITS_PATH}" | sort -u)

    MATCH_COUNT=$(awk -F'\t' '
        function norm(s) { s = toupper(s); gsub(/[ .\/-]/, ".", s); return s }
        { seen[norm($2)] = 1 }
        END { n = 0; for (k in seen) n++; print n }' "${HITS_PATH}")
    log "INFO" "Search completed, found ${MATCH_COUNT} matches"
}

# The most recently listed stocks for one market, newest first. Warrants and rights are
# left out because they are not stocks (NYSE marks them with a " WS" or " RT" symbol suffix).
top_rows() {
    awk -F'\t' -v src="$1" '
        $1 == src && !($3 ~ /[Ww]arrant/ || $3 ~ /(^|[^A-Za-z])[Ww]ts?([^A-Za-z]|$)/ ||
                       $3 ~ /(^|[^A-Za-z])([Rr]ights?|Rts)([^A-Za-z]|$)/ || $2 ~ / (WS[A-Z]?|RT)$/)' "${ALL_PATH}" |
        sort -t "$(printf '\t')" -r -k5,5 |
        awk -v n="${TOPN}" 'NR <= n'
}

table_header() { printf '  %-9s %-14s %-19s %s\n' "SYMBOL" "LISTED ON" "TRIGGERED (ET)" "NAME"; }
table_rows()   { awk -F'\t' '{ printf "  %-9s %-14s %-19s %s\n", $2, $4, $5, substr($3, 1, 44) }'; }

# Describe one list in the report, warning if it is old
list_line() {
    local label="$1" date="$2" rows="$3" age="$4"
    printf '  %-7s list for %s-%s-%s: %s stocks' "${label}" "${date:0:4}" "${date:4:2}" "${date:6:2}" "${rows}"
    if [[ "${age}" -gt 4 ]]; then printf '  ** WARNING: %s days old **' "${age}"; fi
    printf '\n'
}

build_report() {
    local m rows count
    REPORT="SSR Report for ${TODAY} (all times US Eastern)

Lists used:
"
    case " ${MARKET_LIST} " in *" NASDAQ "*)
        [[ -n "${NASDAQ_FILEDATE}" ]] && REPORT+="$(list_line NASDAQ "${NASDAQ_FILEDATE}" "${NASDAQ_ROWS}" "${NASDAQ_AGE}")
" ;;
    esac
    case " ${MARKET_LIST} " in *" NYSE "*)
        [[ -n "${NYSE_FILEDATE}" ]] && REPORT+="$(list_line NYSE "${NYSE_FILEDATE}" "${NYSE_ROWS}" "${NYSE_AGE}")
" ;;
    esac
    REPORT+="
How to read the lists: a stock that triggers is restricted for the rest of that day and all of the next trading day."
    if [[ -n "${NASDAQ_FILEDATE}" ]]; then
        REPORT+="
- NASDAQ's list covers everything restricted today: yesterday's triggers plus today's so far."
    fi
    if [[ -n "${NYSE_FILEDATE}" ]]; then
        REPORT+="
- NYSE publishes its list after the close (about 8:15pm CT) with only that day's triggers, so in the
  morning the newest NYSE list is the previous trading day's, which is what is restricted today.
  NYSE stocks that trigger today show up tonight or in tomorrow morning's report."
    fi
    if [[ -n "${FAILED_NOTES}" ]]; then
        REPORT+="

COULD NOT RETRIEVE:
${FAILED_NOTES}"
    fi

    if [[ "${MATCH_COUNT}" -gt 0 ]]; then
        REPORT+="

YOUR POSITIONS ON THE SSR LISTS (${MATCH_COUNT})
================================================
$(table_header)
$(table_rows < "${HITS_PATH}")"
        SUBJECT="SSR Report ${TODAY}: ${MATCH_COUNT} of your positions on the SSR list"
    else
        REPORT+="

None of your positions were found on the SSR lists."
        SUBJECT="SSR Report ${TODAY}: none of your positions on the SSR list"
    fi
    if [[ -n "${FAILED_NOTES}" ]]; then
        SUBJECT+=" (a list could not be retrieved)"
    fi

    for m in ${MARKET_LIST}; do
        rows=$(top_rows "${m}")
        if [[ -z "${rows}" ]]; then continue; fi
        count=$(printf '%s\n' "${rows}" | wc -l | tr -d ' ')
        REPORT+="

${count} MOST RECENTLY LISTED ON ${m} (newest first)
================================================
$(table_header)
$(printf '%s\n' "${rows}" | table_rows)"
    done
}

notify() {
    if [[ "${PRINT_ONLY}" -eq 1 ]]; then
        log "INFO" "Printing the report (nothing is emailed)"
        printf '%s\n' "${REPORT}"
        return 0
    fi
    log "INFO" "Sending notification email to ${MAILTO}"
    if ! send_mail "${SUBJECT}" "${REPORT}"; then
        log "ERROR" "Failed to send notification email"
        exit 1
    fi
    log "INFO" "Notification sent successfully"
}


####################################################
# Main execution
####################################################

main() {
    log "INFO" "Beginning SSR check for ${TODAY} (markets: ${MARKET_LIST})"
    MATCH_COUNT=0
    REPORT=""
    SUBJECT=""

    setup_temp_files   # temporary files and the cleanup trap
    preflight_check
    fetch_markets
    search
    build_report
    notify

    log "INFO" "SSR check complete"
}

main
