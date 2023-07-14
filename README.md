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
  annotations:
    controller-gen.kubebuilder.io/version: v0.8.0
  generation: 1
  name: myjsons.testing.io
spec:
  conversion:
    strategy: None
  group: testing.io
  names:
    kind: MyJson
    listKind: MyJsons
    plural: myjsons
    singular: myjson
  scope: Namespaced
  versions:
  - additionalPrinterColumns:
    - jsonPath: .status.validation
      name: Status
      type: string
    - jsonPath: .metadata.creationTimestamp
      name: Age
      type: date
    name: v1
    schema:
      openAPIV3Schema:
        description: Policy is the Schema for the policies API
        properties:
          apiVersion:
            description: 'APIVersion defines the versioned schema of this representation
              of an object. Servers should convert recognized schemas to the latest
              internal value, and may reject unrecognized values. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#resources'
            type: string
          kind:
            description: 'Kind is a string value representing the REST resource this
              object represents. Servers may infer this from the endpoint the client
              submits requests to. Cannot be updated. In CamelCase. More info: https://git.k8s.io/community/contributors/devel/sig-architecture/api-conventions.md#types-kinds'
            type: string
          metadata:
            type: object
          spec:
            type: object
            x-kubernetes-preserve-unknown-fields: true
        type: object
    served: true
    storage: true
    subresources: {}
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
        "uid": "ad484ba0-4346-4b38-8f56-bfa0aaecde34",
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

```bash
./cmd.sh 
{"kind":"AdmissionReview","apiVersion":"admission.k8s.io/v1","request":{"uid":"ad484ba0-4346-4b38-8f56-bfa0aaecde34","kind":{"group":"testing.io","version":"v1","kind":"MyJson"},"resource":{"group":"testing.io","version":"v1","resource":"myjsons"},"requestKind":{"group":"testing.io","version":"v1","kind":"MyJson"},"requestResource":{"group":"testing.io","version":"v1","resource":"myjsons"},"name":"testing","namespace":"default","operation":"CREATE","userInfo":{},"object":{"apiVersion":"testing.io/v1","kind":"MyJson","metadata":{"name":"testing","namespace":"default"},"spec":{"color":"blue","pet":"lemon","foo":"bar"}},"oldObject":null,"dryRun":false,"options":null},"response":{"uid":"ad484ba0-4346-4b38-8f56-bfa0aaecde34","allowed":true}}
```

As shown above, the resource passed the policy.

Modify the `cmd.sh` script and produce a violation by changing the value of the `foo` field to something other than `bar`.

```bash
./cmd.sh 
{"kind":"AdmissionReview","apiVersion":"admission.k8s.io/v1","request":{"uid":"ad484ba0-4346-4b38-8f56-bfa0aaecde34","kind":{"group":"testing.io","version":"v1","kind":"MyJson"},"resource":{"group":"testing.io","version":"v1","resource":"myjsons"},"requestKind":{"group":"testing.io","version":"v1","kind":"MyJson"},"requestResource":{"group":"testing.io","version":"v1","resource":"myjsons"},"name":"testing","namespace":"default","operation":"CREATE","userInfo":{},"object":{"apiVersion":"testing.io/v1","kind":"MyJson","metadata":{"name":"testing","namespace":"default"},"spec":{"color":"blue","pet":"lemon","foo":"junk"}},"oldObject":null,"dryRun":false,"options":null},"response":{"uid":"ad484ba0-4346-4b38-8f56-bfa0aaecde34","allowed":false,"status":{"metadata":{},"status":"Failure","message":"\n\nresource MyJson/default/testing was blocked due to the following policies \n\njson-test:\n  test: 'validation error: The foo field must be set to bar. rule test failed at path\n    /spec/foo/'\n"}}}
```

Kyverno just blocked the request.
