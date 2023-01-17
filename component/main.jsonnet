// main template for xelon-csi
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local sc = import 'lib/storageclass.libsonnet';

local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.xelon_csi;

local on_openshift =
  std.startsWith(inv.parameters.facts.distribution, 'openshift');


local raw_manifests = std.parseJson(
  kap.yaml_load_stream(
    '%(base)s/manifests/%(version)s/driver.yaml' % {
      base: inv.parameters._base_directory,
      version: params.manifests_version,
    }
  )
);

local cleanObj(obj) =
  if std.objectHas(obj.metadata, 'namespace') then
    obj {
      metadata+: {
        namespace: params.namespace,
      },
    }
  else if obj.kind == 'CSIDriver' then
    obj {
      apiVersion: 'storage.k8s.io/v1',
    }
  else if obj.kind == 'ClusterRoleBinding' then
    obj {
      subjects: [
        if s.kind == 'ServiceAccount' then
          s {
            namespace: params.namespace,
          }
        else
          s
        for s in super.subjects
      ],
    }
  else obj;

local clean_manifests = std.map(
  cleanObj,
  std.filter(
    function(it) it != null,
    raw_manifests
  )
);


// inject storageclass config managed via component storageclass into all
// storageclasses provided in the upstream manifests.
local fixupStorageClasses = {
  storageclass: [
    s + com.makeMergeable(sc.storageClass(s.metadata.name))
    for s in super.storageclass
  ],
};

local fixupControllerConfig = {
  assert std.length(super.statefulset) == 1,
  statefulset: [
    sts {
      spec+: {
        template+: {
          spec+: {
            containers: [
              c {
                env: std.filter(
                  function(it) it != null,
                  [
                    if std.objectHas(params.controller.env, e.name) then (
                      if params.controller.env[e.name] != null then
                        local ev_raw = params.controller.env[e.name];
                        local ev = if !std.isObject(ev_raw) then
                          { value: ev_raw }
                        else
                          ev_raw;
                        { name: e.name } + ev
                      else
                        null
                    )
                    else
                      e
                    for e in super.env
                  ]
                ),
              }
              for c in super.containers
            ],
          },
        },
      },
    }
    for sts in super.statefulset
  ],
};

local manifests_by_kind =
  std.foldl(
    function(sorted, it) sorted {
      [std.asciiLower(it.kind)]+: [ it ],
    },
    clean_manifests,
    {}
  )
  + fixupStorageClasses
  + fixupControllerConfig;

local custom_rbac =
  if on_openshift then
    [
      kube.RoleBinding('csi-privileged') {
        roleRef_: kube.ClusterRole('system:openshift:scc:privileged'),
        subjects: [
          {
            kind: 'ServiceAccount',
            name: sts.spec.template.spec.serviceAccountName,
            namespace: params.namespace,
          }
          for sts in manifests_by_kind.statefulset
        ] + [
          {
            kind: 'ServiceAccount',
            name: ds.spec.template.spec.serviceAccount,
            namespace: params.namespace,
          }
          for ds in manifests_by_kind.daemonset
        ],
      },
    ]
  else
    [];

local secrets = com.generateResources(
  params.secrets,
  function(name)
    kube.Secret(name) {
      data:: {},
    }
);

// Create one file per resource kind in the output
// XXX: This currently doesn't take into account the apigroups of the
// resources
{
  '00_namespace': kube.Namespace(params.namespace),
  [if std.length(custom_rbac) > 0 then '01_custom_rbac']: custom_rbac,
  [if std.length(secrets) > 0 then '02_secrets']: secrets,
} +
{
  [kind]: manifests_by_kind[kind]
  for kind in std.objectFields(manifests_by_kind)
}
