#!/bin/bash
for plugin in Plugins/*; do
    if [ -d "$plugin" ]; then
      echo "Run tests for $plugin"
      if ! (cd "$plugin" && swift test); then
          echo "Tests failed for plugin $plugin"
          exit 1
      fi
    fi
done
