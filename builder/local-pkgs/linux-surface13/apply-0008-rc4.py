import re
f='drivers/gpu/drm/bridge/panel.c'
s=open(f).read()
old="""	panel_bridge->connector_type = connector_type;
	panel_bridge->panel = drm_panel_get(panel);
"""
new="""	panel_bridge->connector_type = connector_type;
	panel_bridge->panel = drm_panel_get(panel);
	panel_bridge->keep_prepared_on_disable =
		device_property_read_bool(panel->dev,
					  "keep-panel-prepared-on-disable");
"""
assert s.count(old)==1, "panel.c anchor"
open(f,'w').write(s.replace(old,new))

f='drivers/gpu/drm/msm/dp/dp_display.c'
s=open(f).read()
# enable-path restore, in msm_dp_display_atomic_enable
old="""	dp = container_of(msm_dp_display, struct msm_dp_display_private, msm_dp_display);

	rc = msm_dp_display_prepare_link(dp);
"""
new="""	dp = container_of(msm_dp_display, struct msm_dp_display_private, msm_dp_display);

	if (msm_dp_display->is_edp && dp->edp_blanked) {
		if (msm_dp_display->psr_supported)
			msm_dp_display_set_psr(msm_dp_display, false);
		else
			msm_dp_ctrl_on_stream(dp->ctrl, dp->panel);

		dp->edp_blanked = false;
		drm_dbg_dp(msm_dp_display->drm_dev,
			   "restored eDP without a full power cycle\\n");
		return;
	}

	rc = msm_dp_display_prepare_link(dp);
"""
assert s.count(old)==1, "enable anchor"
s=s.replace(old,new)
# post_disable double-disable guard
old="""	msm_dp_display = container_of(dp, struct msm_dp_display_private, msm_dp_display);
	if (dp->is_edp && msm_dp_display->keep_edp_active_on_blank) {
"""
new="""	msm_dp_display = container_of(dp, struct msm_dp_display_private, msm_dp_display);
	if (dp->is_edp && msm_dp_display->edp_blanked)
		return;

	if (dp->is_edp && msm_dp_display->keep_edp_active_on_blank) {
"""
assert s.count(old)==1, "post_disable anchor"
open(f,'w').write(s.replace(old,new))
print("ALL 3 HUNKS APPLIED")
