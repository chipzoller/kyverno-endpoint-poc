# kyverno-endpoint-poc
PoC on how Kyverno can be called as an endpoint from more than just the Kubernetes API.

## Overview

Kyverno is an admission controller for Kubernetes and is used to receive HTTP callbacks from the Kubernetes API server. All of its plumbing is specific to receiving and then replying to just those requests. But it is also possible to call Kyverno for use cases like validations of generic JSON from any other location in the cluster. For example, another service in the cluster exists which would like to use Kyverno as an engine to validate some arbitrary (but consistently structured) JSON in order to decide what it should do next.

This repo is a first attempt at a PoC on how this can be achieved.

## Setup

We need a barebones CRD which can serve as the placeholder for the structured data Kyverno must process. In order for a Kyverno policy to be written, it must have a corresponding CRD. The CRD can be extremely minimal. I've created a CRD for a mock resource called a `MyJson`.

```yaml
apiVersion: apiextensions.k8s.io/v1
kind: CustomResourceDefinition
metadata:
  name: myjsons.testing.io
spec:
  group: testing.io
  names:
    kind: MyJson
    listKind: MyJsons
    plural: myjsons
    singular: myjson
  scope: Namespaced
  versions:
  - name: v1
    schema:
      openAPIV3Schema:
        description: This is a boilerplate custom resource used for testing of MyJson resources.
        properties:
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
        type: object
    served: true
    storage: true
```

Next, we can write a Kyverno policy using its simplistic pattern elements which match on the `MyJson` resource. This simple policy just states that the `foo` field must equal `bar`. In order to process generic JSON, it must be masqueraded as a Kubernetes resource with boilerplate fields such as `apiVersion`, `kind`, `metadata`, and `spec`. The `spec` object will be used as a container to hold the ultimate JSON data our external tool would like to validate.

```yaml
apiVersion: kyverno.io/v1
kind: ClusterPolicy
metadata:
  name: json-test
spec:
  background: false
  validationFailureAction: Enforce
  rules:
  - name: test
    match:
      any:
      - resources:
          kinds:
          - MyJson
    validate:
      message: The foo field must be set to bar.
      pattern:
        spec:
          foo: bar
```

On the system/application from which we wish to call into Kyverno, we need to create a scaffolding AdmissionReview JSON document as this is the content Kyverno is trained to process. Note here that some data has already been populated into the `spec` but will be overwritten/inserted at runtime. Assume this is a file called `boilerplate.json` to be used in the next step.

```json
{
    "kind": "AdmissionReview",
    "apiVersion": "admission.k8s.io/v1",
    "request": {
        "uid": "ffffffff-ffff-ffff-ffff-ffffffffffff",
        "kind": {
            "group": "testing.io",
            "version": "v1",
            "kind": "MyJson"
        },
        "resource": {
            "group": "testing.io",
            "version": "v1",
            "resource": "myjsons"
        },
        "requestKind": {
            "group": "testing.io",
            "version": "v1",
            "kind": "MyJson"
        },
        "requestResource": {
            "group": "testing.io",
            "version": "v1",
            "resource": "myjsons"
        },
        "name": "testing",
        "namespace": "default",
        "operation": "CREATE",
        "userInfo": null,
        "roles": null,
        "clusterRoles": null,
        "object": {
            "apiVersion": "testing.io/v1",
            "kind": "MyJson",
            "metadata": {
              "name": "testing",
              "namespace": "default"
            },
            "spec": {
              "color": "red",
              "pet": "dog",
              "foo": "dizzy"
            }
          },
        "oldObject": null,
        "dryRun": false,
        "options": null
    },
    "oldObject": null,
    "dryRun": false,
    "options": null
}
```

We can then proceed to mock this all up in a simple script using `jq` and `curl`. The `jq` command will take some "new" JSON data and merge it into the boilerplate AdmissionReview document saved in `boilerplate.json`. At the last step, `curl` will call out to the Kyverno Service (assumed to be at `kyverno-svc.kyverno`) with the fully-composed data which got merged into a new file called `output.json`.

```bash
#!/bin/bash

jq --argjson i '{"foo": "bar", "pet": "lemon", "color": "blue"}' '.request.object.spec |= . + $i' boilerplate.json > output.json
curl -k -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' https://kyverno-svc.kyverno:443/validate/fail --data-binary "@output.json"
```

We can execute the script from another Pod running inside the same cluster assuming it has network connectivity to Kyverno (i.e., there is no applicable NetworkPolicy restricting its communication). The below output is the result of executing the above script as a file called `cmd.sh`.

```json
./cmd.sh 
{
  "kind": "AdmissionReview",
  "apiVersion": "admission.k8s.io/v1",
  "request": {
    "uid": "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "kind": {
      "group": "testing.io",
      "version": "v1",
      "kind": "MyJson"
    },
    "resource": {
      "group": "testing.io",
      "version": "v1",
      "resource": "myjsons"
    },
    "requestKind": {
      "group": "testing.io",
      "version": "v1",
      "kind": "MyJson"
    },
    "requestResource": {
      "group": "testing.io",
      "version": "v1",
      "resource": "myjsons"
    },
    "name": "testing",
    "namespace": "default",
    "operation": "CREATE",
    "userInfo": {},
    "object": {
      "apiVersion": "testing.io/v1",
      "kind": "MyJson",
      "metadata": {
        "name": "testing",
        "namespace": "default"
      },
      "spec": {
        "color": "blue",
        "pet": "lemon",
        "foo": "bar"
      }
    },
    "oldObject": null,
    "dryRun": false,
    "options": null
  },
  "response": {
    "uid": "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "allowed": true
  }
}
```

Look at the final `response` object and note how `response.allowed` is set to `true` indicating that Kyverno said this resource passed the policy definition.

Modify the `cmd.sh` script and produce a violation by changing the value of the `foo` field to something other than `bar`. I'll use `foo: junk` instead.

```bash
#!/bin/bash

jq --argjson i '{"foo": "junk", "pet": "lemon", "color": "blue"}' '.request.object.spec |= . + $i' boilerplate.json > output.json
curl -k -X POST -H 'Content-Type: application/json' -H 'Accept: application/json' https://kyverno-svc.kyverno:443/validate/fail --data-binary "@output.json"
```

Execute the script once again.

```json
./cmd.sh 
{
  "kind": "AdmissionReview",
  "apiVersion": "admission.k8s.io/v1",
  "request": {
    "uid": "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "kind": {
      "group": "testing.io",
      "version": "v1",
      "kind": "MyJson"
    },
    "resource": {
      "group": "testing.io",
      "version": "v1",
      "resource": "myjsons"
    },
    "requestKind": {
      "group": "testing.io",
      "version": "v1",
      "kind": "MyJson"
    },
    "requestResource": {
      "group": "testing.io",
      "version": "v1",
      "resource": "myjsons"
    },
    "name": "testing",
    "namespace": "default",
    "operation": "CREATE",
    "userInfo": {},
    "object": {
      "apiVersion": "testing.io/v1",
      "kind": "MyJson",
      "metadata": {
        "name": "testing",
        "namespace": "default"
      },
      "spec": {
        "color": "blue",
        "pet": "lemon",
        "foo": "junk"
      }
    },
    "oldObject": null,
    "dryRun": false,
    "options": null
  },
  "response": {
    "uid": "ffffffff-ffff-ffff-ffff-ffffffffffff",
    "allowed": false,
    "status": {
      "metadata": {},
      "status": "Failure",
      "message": "resource MyJson/default/testing was blocked due to the following policies json-test:  test: validation error: The foo field must be set to bar. rule test failed at path /spec/foo/"
    }
  }
}
```

The output above has been slightly modified with respect to control characters to ease readibility in this document. Notice the `response` object here has `response.allowed: false` indicating the request is denied. Kyverno just blocked the request and responded with the same message in the policy.

## Notes

Since these requests/responses do not travel between the Kubernetes API server, there is no risk of "good" resources being persisted into the cluster.

One should note that Kubernetes Events will be produced when Kyverno detects a violation. There is currently no way to disable such Events on a per-policy basis.

In the above hacky script, I am using the `-k` flag to `curl` to ignore TLS trust. If this method were operationalized, one would probably wish to establish proper trust.

There is nothing precluding this concept from working via services external to the cluster, one would need only modify the Kyverno Service or create another which exposes it externally via either a NodePort or LoadBalancer type Service.
