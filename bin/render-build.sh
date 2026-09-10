#!/usr/bin/env bash
set -o errexit

BUNDLE_FROZEN=true bundle install
bundle exec rails assets:precompile
bundle exec rails assets:clean
