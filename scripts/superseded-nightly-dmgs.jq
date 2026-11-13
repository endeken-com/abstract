# The nightly release's DMGs that the appcast no longer needs, one name per line.
# Input: `gh release view nightly --json assets`. env.KEEP is the new DMG's name.
# Keeps the new DMG and the newest other one (Pages caches appcast.xml for up to ten
# minutes, so some clients still follow the previous feed's link). Every other asset,
# like the plugin catalog's plugins.json and its zips, is never selected (ABS-158).
[.assets[] | select((.name | endswith(".dmg")) and .name != env.KEEP)]
| sort_by(.createdAt) | reverse | .[1:] | .[].name
