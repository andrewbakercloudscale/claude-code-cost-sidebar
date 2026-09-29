# Check AP -- the Recent trend line names days as ordinals ("27th"), so a
# bare day number next to a dollar figure cannot be read as a count.
check_AP_ordinal_day() {
  sandbox_new AP
  load_panel 10 12 ""
  local d want
  for d in 01:1st 02:2nd 03:3rd 04:4th 11:11th 12:12th 13:13th 21:21st 22:22nd 23:23rd 24:24th 31:31st; do
    want=${d#*:}
    assert_eq "day ${d%%:*}" "$want" "$(ordinal_day "${d%%:*}")"
  done
}
