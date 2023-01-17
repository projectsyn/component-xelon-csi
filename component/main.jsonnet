// main template for xelon-csi
local com = import 'lib/commodore.libjsonnet';
local kap = import 'lib/kapitan.libjsonnet';
local kube = import 'lib/kube.libjsonnet';
local sc = import 'lib/storageclass.libsonnet';

local inv = kap.inventory();
// The hiera parameters for the component
local params = inv.parameters.xelon_csi;


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

local manifests_by_kind =
  std.foldl(
    function(sorted, it) sorted {
      [std.asciiLower(it.kind)]+: [ it ],
    },
    clean_manifests,
    {}
  ) + fixupStorageClasses;

// Create one file per resource kind in the output
// XXX: This currently doesn't take into account the apigroups of the
// resources
{
  '00_namespace': kube.Namespace(params.namespace),
} +
{
  [kind]: manifests_by_kind[kind]
  for kind in std.objectFields(manifests_by_kind)
}
