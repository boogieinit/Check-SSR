# Check-SSR

Checks the NASDAQ and NYSE Short Sale Restriction (SSR) lists for the stocks you own and emails you one report.

Under SEC Rule 201, a stock that falls 10% or more from the prior day's close is put on an SSR list: short selling is restricted for the rest of that day and all of the next trading day. If one of your positions shows up, it has just had a big drop, which is worth knowing before the market opens.

## What you get

One email (or screen report) covering both markets:

- **Your positions** found on either list, with the time each one triggered.
- **The most recently listed stocks** on each market, newest first. Warrants and rights are left out.
- A note of which list date was used, and a warning if a list is stale or could not be retrieved.

Example (the tickers here are only an illustration):

```
SSR Report for 20261111 (all times US Eastern)

Lists used:
  NASDAQ  list for 2026-11-11: 799 stocks
  NYSE    list for 2026-11-11: 56 stocks

YOUR POSITIONS ON THE SSR LISTS (2)
================================================
  SYMBOL    LISTED ON      TRIGGERED (ET)      NAME
  DNA       NYSE           2026-11-11 14:19:52 Ginkgo Bioworks Holdings, Inc.
  ZIP       NYSE           2026-11-11 14:48:45 ZipRecruiter, Inc.

5 MOST RECENTLY LISTED ON NASDAQ (newest first)
================================================
  SYMBOL    LISTED ON      TRIGGERED (ET)      NAME
  PRPL      NASDAQ         2026-11-11 16:00:00 Purple Innovation, Inc.
  DRIO      NASDAQ         2026-11-11 15:59:59 DarioHealth Corp.
  ...
```

## Install

```
git clone https://github.com/boogieinit/Check-SSR.git
cd Check-SSR
./install.sh
```

The installer is safe to run again. It:

- installs `CheckSSR.sh` as `~/bin/checkssr` (make sure `~/bin` is on your PATH),
- creates a config file at `~/.config/CheckSSR/config.sh`,
- creates a positions file at `~/Documents/CheckSSR/positions.txt` (examples only, commented out),
- optionally schedules a weekday run with launchd (macOS) at 8:40am Central, just after the open.

## Set up

1. **Config:** edit `~/.config/CheckSSR/config.sh` and set `MAILTO` to your email address.
2. **Positions:** edit `positions.txt` and list your tickers, one per line. The same list is checked against both markets, so list everything you own. Lines starting with `#` are ignored. Class shares and preferreds can be written with a dot (`BRK.B`, `BH.A`); the script matches NYSE's own notation (`BH A`, `ABR PRD`) automatically.
3. **Try it** without sending any email: `checkssr --print`

## Usage

```
checkssr [options]
  -m, --market LIST   Markets to check: nasdaq, nyse or all (default: from config, else all)
  -d, --date YYYYMMDD Look for lists on or before this date (default: today)
  -n, --top N         How many "most recently listed" stocks to show per market (default 10)
  -p, --print         Print the report instead of emailing it (nothing is sent)
  -h, --help          Show this help
```

`--date` is handy for checking how a past day looked. Config settings (all optional except `MAILTO` and `STOCKS`): `MARKETS="NASDAQ NYSE"`, `TOPN=10`.

## How the two lists differ

| | NASDAQ | NYSE (NYSE, NYSE American, NYSE Arca) |
|---|---|---|
| Source | `nasdaqtrader.com`, a text file | `ftp.nyxdata.com`, one Excel file per day |
| Published | About 5am ET, updated during the day | After the close (about 8:15pm CT) |
| Holds | Everything restricted today: yesterday's triggers plus today's so far | Only that day's triggers |

So in the morning NASDAQ's list is complete for today, and the newest NYSE list is the previous trading day's, which is the set restricted today. NYSE stocks that trigger today show up in the evening or in the next morning's report. When a day has no list (weekends, holidays), the latest available one is used and the report says which date it is.

Not covered: other exchanges that list securities, such as Cboe BZX (mostly ETFs).

## Sending email

Delivery works best with [msmtp](https://marlam.de/msmtp/) and an authenticated mail server, for example Gmail with an app password kept in the macOS Keychain. The system `mail` command is used if msmtp is not installed, but mail sent straight from a home network is often blocked. A sample `~/.msmtprc`:

```
defaults
auth           on
tls            on
tls_starttls   on
tls_trust_file /etc/ssl/cert.pem

account        gmail
host           smtp.gmail.com
port           587
from           you@gmail.com
user           you@gmail.com
passwordeval   security find-generic-password -a "you@gmail.com" -s msmtp-gmail -w

account default : gmail
```

Add the password to the Keychain with `security add-generic-password -a "you@gmail.com" -s msmtp-gmail -w` (it prompts for the password), then protect the file with `chmod 600 ~/.msmtprc`.

## Requirements

- bash, curl, awk
- `msmtp` or `mail`, to send email (not needed with `--print`)
- `python3`, only for the NYSE list. It reads the Excel file with a small standard-library-only reader that is built into the script, so there are no packages to install.

## Notes

- Everything is one script, `CheckSSR.sh`. Each market has a small function that downloads its list and converts it to a common format; matching, the most-recent tables and the email are shared. Adding another market means writing one more such function.
- The report is always sent in the email body. Older versions could send attachments with `mpack`, which was dropped because it is not available in Homebrew.
- Logs are written to `~/Library/Logs/CheckSSR/`.

## License

MIT - see [LICENSE](LICENSE).
