# Check BQ -- the figures formatted in the shell are the figures awk gave.
#
# The slow tick's money, token and colour helpers each ran an awk. Their _v
# forms do the same in the shell where that is provably the same answer
# (fmt_money_v, fmt_m_v, ctx_tier_color_v, panel_day_v) and in one awk where
# it is not (tier_color_v, threshold_color_v). A rounding slip here would
# change what the panel shows, so each is compared with its original over
# values chosen to sit on the edges: halves, values just under 1, negatives,
# zeros, exponents, empty strings.
check_BQ_builtin_formats() {
  sandbox_new BQ
  load_panel 10 12 ""
  local v got want bad=0 n=0
  for v in 0 0.0 0.004 0.005 0.0051 0.125 0.135 0.5 0.994 0.995 0.999 1 1.5 2.5 3.5 12.345 12.355 \
           99.5 100.49 4015.9487313499963 -0.4 -0.5 -0.75 -12.5 1e-05 2.5e3 "" abc .5 5. 007.25 \
           123456789.125 0.3333333333333333; do
    fmt_money_v got "$v"; want=$(fmt_money "$v"); n=$(( n + 1 ))
    [ "$got" = "$want" ] || { bad=$(( bad + 1 )); printf '    fmt_money %s: %s vs %s\n' "$v" "$got" "$want" >&2; }
  done
  assert_eq "fmt_money_v is fmt_money ($n values)" 0 "$bad"
  bad=0 n=0
  for v in 0 1 5000 125000 135000 155000 999999 1000000 1005000 1015000 162825 400000 1234567890 "" 1.5e6; do
    fmt_m_v got "$v"; want=$(fmt_m "$v"); n=$(( n + 1 ))
    [ "$got" = "$want" ] || { bad=$(( bad + 1 )); printf '    fmt_m %s: %s vs %s\n' "$v" "$got" "$want" >&2; }
  done
  assert_eq "fmt_m_v is fmt_m ($n values)" 0 "$bad"
  bad=0 n=0
  for v in -5 0 29 30 31 50 51 70 71 100 30.5 abc ""; do
    ctx_tier_color_v got "$v" 30 50 70; want=$(ctx_tier_color "$v" 30 50 70); n=$(( n + 1 ))
    [ "$got" = "$want" ] || { bad=$(( bad + 1 )); printf '    ctx_tier %s\n' "$v" >&2; }
  done
  assert_eq "ctx_tier_color_v is ctx_tier_color ($n values)" 0 "$bad"
  bad=0 n=0
  local a
  for v in 0 4.99 5 12 12.3 16.4 24.6 24.61 100 ""; do
    for a in 0 8.2 16.4 ""; do
      tier_color_v got "$v" "$a" 1.5 2.0 5; want=$(tier_color "$v" "$a" 1.5 2.0 5); n=$(( n + 1 ))
      [ "$got" = "$want" ] || { bad=$(( bad + 1 )); printf '    tier %s %s\n' "$v" "$a" >&2; }
    done
    threshold_color_v got "$v" 3 6; want=$(threshold_color "$v" 3 6); n=$(( n + 1 ))
    [ "$got" = "$want" ] || { bad=$(( bad + 1 )); printf '    threshold %s\n' "$v" >&2; }
  done
  assert_eq "tier_color_v and threshold_color_v are the originals ($n cases)" 0 "$bad"
  # Days ago, against date itself, through both DST changes of 2026 in a
  # zone that has them, at hours that put the change on either side.
  bad=0 n=0
  local t d
  for t in 1773018000 1773025200 1773032400 1774746000 1774753200 1793952000 1793959200 1793966400; do
    for d in 0 1 2 6 7 29 58; do
      got=$(export TZ=America/New_York; PANEL_FAKE_NOW=$t; panel_day_v x "$d" %Y-%m-%d; printf "%s" "$x")
      want=$(TZ=America/New_York date -r "$t" -v-"$d"d +%Y-%m-%d); n=$(( n + 1 ))
      [ "$got" = "$want" ] || { bad=$(( bad + 1 )); printf '    day %s -%s: %s vs %s\n' "$t" "$d" "$got" "$want" >&2; }
    done
  done
  assert_eq "panel_day_v is date -v-Nd ($n cases)" 0 "$bad"
  return 0
}
