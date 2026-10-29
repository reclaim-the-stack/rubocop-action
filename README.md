# rubocop-action

This GitHub action runs rubocop and posts offences as inline comments on pull requests. When offences are resolved, the comments are fully deleted, making for clean pull requests without noisy history.

This action was created to replace the unmaintained [Hound](https://houndci.com/) service from Thoughtbot.

## Usage

Create a `.github/workflows/rubocop.yml` file in your repository:

```yaml
name: Rubocop

on: pull_request

permissions:
  contents: read
  pull-requests: write

jobs:
  rubocop:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
      - uses: reclaim-the-stack/rubocop-action@v1
```

### Configuration

#### `github_token`

The GitHub token to use for interacting with the GitHub API (eg. to managed comments). By default we use the token which is automatically provided by GitHub Actions.

#### `gem_versions`

By default `rubocop` / `rubocop-rails` and `rubocop-rspec` gems are installed. Check the [action.yml](action.yml) file for the current default version of the gems installed by this action.

You can override the gems and versions either by:

Specifying `gem_versions` as `Gemfile` in which case we remove all gems except those with `rubocop` in their name (and `syntax_tree`) from your `Gemfile` and run `bundle install`, installing the versions locked in your `Gemfile.lock`. Rubocop is then run via `bundle exec`.

```yaml
      - uses: reclaim-the-stack/rubocop-action@v1
        with:
          gem_versions: Gemfile
```

Specifying `gem_versions` in the standard `gem install` format.

```yaml
      - uses: reclaim-the-stack/rubocop-action@v1
        with:
          gem_versions: rubocop:1.18.3 rubocop-rspec:2.0.0 rubocop-<some-other-plugin>:1.2.0
```

#### `rubocop_arguments`

Allows you to pass additional arguments to rubocop. E.g.

```yaml
      - uses: reclaim-the-stack/rubocop-action@v1
        with:
          rubocop_arguments: --config .rubocop.yml
```

#### `failure_exit_code`

The exit code used when offences are found. Defaults to `108`. Set it to `0` to post comments on offences without failing the build.

```yaml
      - uses: reclaim-the-stack/rubocop-action@v1
        with:
          failure_exit_code: 0
```

### Versioning

The `v1` tag tracks the latest `v1.x.x` release. Pin to a specific release, e.g. `reclaim-the-stack/rubocop-action@v1.2.0`, if you prefer to opt in to updates manually.

### Known issues

We don't handle hitting API rate limits on the GitHub API. Presumably this could end up being a problem if you create a pull request with a ton of offences requiring inline comments. Shouldn't be a problem for normal use though.
