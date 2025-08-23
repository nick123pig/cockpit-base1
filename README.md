# cockpit-base1

This package provides a minimal, repackaged ESM build of the [Cockpit base1 library](https://cockpit-project.org/guide/latest/api-base1.html) for convenience. **This is not the recommended way to consume Cockpit**—the Cockpit project suggests using their official distribution and integration methods. However, for simple or experimental use cases, this package can be used as a drop-in ESM module.

### ⚠️ Not Officially Supported
This repackaging is not endorsed or supported by the Cockpit project. Use at your own risk.

## Usage

Install via npm:

```sh
npm install cockpit-base1
```

Import and use in your project:

```js
import cockpit from 'cockpit-base1';
// ...use cockpit as needed
```

## License

See [Cockpit upstream license](https://github.com/cockpit-project/cockpit/blob/main/COPYING).