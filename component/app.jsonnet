local kap = import 'lib/kapitan.libjsonnet';
local inv = kap.inventory();
local params = inv.parameters.xelon_csi;
local argocd = import 'lib/argocd.libjsonnet';

local app = argocd.App('xelon-csi', params.namespace);

{
  'xelon-csi': app,
}
