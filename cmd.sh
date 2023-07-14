#!/bin/bash

jq --argjson i '{"foo": "bar", "pet": "lemon", "color": "blue"}' '.request.object.spec |= . + $i' boilerplate.json > output.json
curl -k -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' https://kyverno-svc.kyverno:443/validate/fail --data-binary "@output.json"