## `dependabot-npm_and_yarn`

PHP support for [`dependabot-core`][core-repo].

### Running locally

1. Install native helpers
   ```
   $ helpers/build helpers/install-dir/npm_and_yarn
   ```

2. Install Ruby dependencies
   ```
   $ bundle install
   ```

3. Run tests
   ```
   $ bundle exec rspec spec
   ```

[core-repo]: https://github.com/dependabot/dependabot-core
