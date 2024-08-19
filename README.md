# TestProf AI GitHub Action

This GitHub Action allows you to optimize Rails tests via [TestProf][] and [Claude AI][Claude].

The action performs the given test file profiling and refactors it to speed up the execution (using `let_it_be` and `before_all` helpers from TestProf). It opens a PR and shares the refactoring progress as it executes.

## Requirements

- **Configured testing environment**. This action runs your tests during the refactoring (to verify the correctness), so you must configure it as for regular tests.

- **GitHub token permissions**. This action uses the default `GITHUB_TOKEN` provided by GitHub Actions. You must configure its permissions (Settings -> Actions -> Workflow permissions): enable "Read and write permissions" and "Allow GitHub Actions to create and approve pull requests".

## Inputs

- **api-key** (required): you API key to communicate with Claude API.
- **issue-number**: GitHub issue number to read the task from (the issue must contain the path to the test file to refactor).
- **test-file-path**: Path to test file to refactor. **IMPORTANT:** one of the `issue-number` or `test-file-path` must be specified.
- **base-branch** (optional, default: main): Base Git branch to open a PR against.
- **test-command** (optional, default: `bundle exec rspec`): Command to execute a test file.
- **example-patch-path** (optional): Path to the example Git patch to use by AI's prompt.
- **custom-prompt-path** (optional): Path to the custom AI prompt file.

## Example

We suggest to use GitHub Issues to initiate refactoring tasks. Here is an example workflow:

```yml
name: TestProf AI

on:
  issues:
    types: [labeled]

jobs:
  optimize:
    # IMPORTANT: Only run this workflow for explicitly labeled issues
    if: github.event.label.name == 'test-prof'
    runs-on: ubuntu-latest

    env:
      RAILS_ENV: test
      # ... here goes your environment setup

    steps:
      - uses: actions/checkout@v4
      - uses: ruby/setup-ruby@v1
        with:
          bundler-cache: true
      - name: Prepare app
        run: |
          bundle exec rails db:test:prepare

      - name: Run TestProf AI
        uses: test-prof/test-prof-aiptimize-action@main
        with:
          api-key: ${{ secrets.CLAUDE_API_KEY }}
          issue-number:  ${{ github.event.issue.number }}
```

Here is also an example [issue template](./ISSUE_TEMPLATE/test_prof.yml).

[TestProf]: https://github.com/test-prof/test-prof
[Claude]: https://claude.ai
