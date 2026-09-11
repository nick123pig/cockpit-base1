# cockpit-base1

This package provides a minimal, repackaged ESM build of the [Cockpit base1 library](https://cockpit-project.org/guide/latest/api-base1.html) for convenience. **This is not the recommended way to consume Cockpit**—the Cockpit project suggests using their official distribution and integration methods. However, for simple or experimental use cases, this package can be used as a drop-in ESM module. Use at your own risk.

## Choosing a version

`cockpit-base1` maps 1:1 to cockpit releases. The cockpit version becomes the first two numbers of our semver; the patch is **our build counter**, not cockpit's:

| cockpit release | package versions | install range |
|---|---|---|
| 323 | `323.0.x` | `^323` |
| 356.3 (point release) | `356.3.x` | `^356.3` |

Most of the time, just use the cockpit version you're on with a `^` range — the patch is bumped on every rebuild, so never pin it:

```json
"dependencies": { "cockpit-base1": "^323" }
```

where `323` is your version of cockpit. `^323` will give you the newest `323.0.x` build, i.e. the latest packaging of cockpit 323.

A few things to know:

- **Point releases are their own line**: cockpit `356.3` lives in `356.3.x`, so `^356` (plain 356) and `^356.3` (the 356.3 point release) are different lines. Pin the minor when you care. (`line-356.3` and similar dist-tags exist per line.)
- Only the newest cockpit release carries npm's `latest` tag, so `npm install cockpit-base1` gives you the newest cockpit — add the range above to stay on your version.
