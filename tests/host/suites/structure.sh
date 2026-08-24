# Repository structure host tests.
# Sourced by tests/host/run-tests.sh.

# ---------------------------------------------------- monitoring page split --
t "Watchcat and Scheduled Restart have separate pages" "yes" \
  "$([ -f quecdeck/www/watchcat.html ] && [ -f quecdeck/www/scheduled-restart.html ] && [ ! -e quecdeck/www/monitoring.html ] && echo yes || echo no)"
t "monitoring pages load only their own controllers" "yes" \
  "$(grep -q 'x-data="quecdeckWatchCat()"' quecdeck/www/watchcat.html && grep -q 'js/watchcat.js' quecdeck/www/watchcat.html && ! grep -q 'Scheduled Restart\|scheduled-restart' quecdeck/www/watchcat.html && grep -q 'x-data="quecdeckScheduledRestart()"' quecdeck/www/scheduled-restart.html && grep -q 'js/scheduled-restart.js' quecdeck/www/scheduled-restart.html && ! grep -q 'Watchcat\|watchcat' quecdeck/www/scheduled-restart.html && echo yes || echo no)"
t "monitoring controllers call only their own endpoints" "yes" \
  "$(! grep -q 'scheduled_restart' quecdeck/www/js/watchcat.js && ! grep -q 'watchcat' quecdeck/www/js/scheduled-restart.js && grep -q 'get_watchcat_status' quecdeck/www/js/watchcat.js && grep -q 'get_scheduled_restart' quecdeck/www/js/scheduled-restart.js && echo yes || echo no)"
t "navigation exposes both monitoring pages" "yes" \
  "$(grep -q "href: '/watchcat.html', label: 'Watchcat'" quecdeck/www/js/nav.js && grep -q "href: '/scheduled-restart.html', label: 'Scheduled Restart'" quecdeck/www/js/nav.js && grep -q 'href="/watchcat.html"' quecdeck/www/deviceinfo.html && grep -q 'href="/scheduled-restart.html"' quecdeck/www/deviceinfo.html && ! grep -q '/monitoring.html' quecdeck/www/js/nav.js quecdeck/www/deviceinfo.html && echo yes || echo no)"

# ------------------------------------------ root-home migration lifecycle ---
# The legacy root bin was world-writable. These ordering assertions prevent a
# future cleanup from putting it back in the updater's command search path or
# running the destructive migration before a verified release and rollback
# snapshot exist.
t "installer PATH excludes legacy root bin" "yes" \
  "$(grep '^export PATH=' quecdeck.sh | grep -qv '/usrdata/root/bin' && echo yes || echo no)"
t "updater PATH excludes legacy root bin" "yes" \
  "$(grep '^export PATH=' update_quecdeck.sh | grep -qv '/usrdata/root/bin' && echo yes || echo no)"
_harden_line=$(grep -n '^[[:space:]]*harden_root_home ||' update_quecdeck.sh | cut -d: -f1)
_commit_line=$(grep -n '^[[:space:]]*_swap_committed=1$' update_quecdeck.sh | tail -1 | cut -d: -f1)
_helper_line=$(grep -n 'ln -sf "\$QUECDECK_DIR/atcli" /usrdata/root/bin/atcli' update_quecdeck.sh | head -1 | cut -d: -f1)
t "root home hardens after rollback becomes possible" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -gt "$_commit_line" ] && echo yes || echo no)"
t "root home hardens before helper writes" "yes" \
  "$([ -n "$_harden_line" ] && [ "$_harden_line" -lt "$_helper_line" ] && echo yes || echo no)"
t "rollback restores password helper copies" "2" \
  "$(sed -n '/^_revert_swap() {/,/^}/p' update_quecdeck.sh | grep -c 'cp -f.*quecdeck.*passwd.*usrdata/root/bin')"
t "uninstall clears root-home migration marker" "yes" \
  "$(sed -n '/^uninstall_quecdeck_components() {/,/^}/p' quecdeck.sh | grep -q 'rm -f.*ROOT_HOME_HARDENED' && echo yes || echo no)"

# Every shipped unit must carry the marker or both sweeps go blind to it and it
# stays installed and enabled forever. The ci-checks.sh script also checks this. It is repeated
# here because run-tests.sh is what the pre-commit hook runs, so a marker-less
# unit is blocked at commit time rather than discovered in CI.
for _u in quecdeck/systemd/*.service; do
    [ -f "$_u" ] || continue
    t "unit self-identifies: $(basename "$_u")" "yes" \
      "$(grep -qE '^Exec(Start|StartPre|StartPost|Reload|Stop|StopPost)=.*/usrdata/quecdeck(/|[[:space:]]|$)' "$_u" && echo yes || echo no)"
done

# ---------------------------------------------------------- JS structure ----
js_fail=0
for f in quecdeck/www/js/*.js; do
    case "$f" in *.min.js) continue ;; esac
    out=$(perl tests/host/support/jscheck.pl "$f")
    if [[ "$out" == *": OK" ]]; then
        pass=$((pass + 1))
    else
        fail=$((fail + 1)); js_fail=1
        echo "FAIL: jscheck $out"
    fi
done
