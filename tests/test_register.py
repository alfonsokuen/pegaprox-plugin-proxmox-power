# -*- coding: utf-8 -*-
"""Validate the plugin entry point wires every documented route."""


def test_register_wires_all_routes(plugin, monkeypatch):
    captured = {}

    def fake_register(plugin_id, path, handler):
        captured.setdefault(plugin_id, {})[path] = handler

    # Patch the symbol the plugin imported at module load.
    monkeypatch.setattr(plugin, 'register_plugin_route', fake_register)
    plugin.register(app=None)

    routes = captured.get('proxmox-power', {})
    expected = {'ui', 'clusters', 'inventory', 'config', 'config/save',
                'preflight', 'plan', 'execute', 'job', 'jobs'}
    assert set(routes) == expected
    assert all(callable(h) for h in routes.values())
