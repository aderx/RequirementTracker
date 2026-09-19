"""Exercise real MCP stdio and concurrent Native Host writes using isolated data."""
import concurrent.futures
import hashlib
import json
import os
from pathlib import Path
import sqlite3
import struct
import subprocess
import tempfile
import uuid

root = Path(__file__).resolve().parents[2]
bin_dir = Path(os.environ.get('REQUIREMENT_TRACKER_BIN_DIR', root / '.build/out/Products/Debug'))

def host(database, key):
    payload = json.dumps({'type': 'upsertJiraRequirement', 'payload': {'issueKey': key, 'jiraURL': 'https://jira.example/browse/' + key, 'title': '需求 ' + key}}).encode()
    result = subprocess.run([str(bin_dir / 'JiraRequirementNativeHost')], input=struct.pack('<I', len(payload)) + payload,
                            env={**os.environ, 'REQUIREMENT_TRACKER_DATABASE_FILE': str(database)}, capture_output=True, check=True)
    length = struct.unpack('<I', result.stdout[:4])[0]
    response = json.loads(result.stdout[4:4 + length])
    assert response['ok'], response

def rpc(process, obj):
    process.stdin.write(json.dumps(obj) + '\n')
    process.stdin.flush()
    return json.loads(process.stdout.readline())

def request(process, method, params=None, id=1):
    return rpc(process, {'jsonrpc': '2.0', 'id': id, 'method': method, 'params': params or {}})

def initialize(process):
    response = request(process, 'initialize', {'protocolVersion': '2025-06-18', 'capabilities': {}, 'clientInfo': {'name': 'checks', 'version': '1'}})
    assert response['result']['protocolVersion'] == '2025-06-18'
    process.stdin.write('{"jsonrpc":"2.0","method":"notifications/initialized"}\n')
    process.stdin.flush()

with tempfile.TemporaryDirectory(prefix='requirement-mcp-') as folder:
    database = Path(folder) / 'requirements.sqlite'
    # First startup and simultaneous writes must not lose one another's records.
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        list(pool.map(lambda i: host(database, f'TEST-{i}'), range(12)))
    with sqlite3.connect(database) as connection:
        assert connection.execute('SELECT count(*) FROM requirements').fetchone()[0] == 12
        assert connection.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert connection.execute('PRAGMA foreign_key_check').fetchall() == []
    before = hashlib.sha256(database.read_bytes()).hexdigest()
    with subprocess.Popen([str(bin_dir / 'RequirementTrackerMCP'), '--database', str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        assert request(process, 'tools/list')['error']['code'] == -32002
        initialize(process)
        tools = request(process, 'tools/list')['result']['tools']
        assert len(tools) == 5
        assert sum(t['annotations']['readOnlyHint'] for t in tools) == 4
        assert next(t for t in tools if t['name'] == 'advance_requirement')['annotations']['idempotentHint']
        def call(name, args=None):
            return request(process, 'tools/call', {'name': name, 'arguments': args or {}})['result']
        stats = call('get_requirement_stats')['structuredContent']
        assert stats['total'] == 12
        page = call('list_requirements', {'limit': 5})['structuredContent']
        page2 = call('list_requirements', {'limit': 5, 'offset': page['nextOffset']})['structuredContent']
        assert len(page['requirements']) == 5
        assert not set(r['id'] for r in page['requirements']) & set(r['id'] for r in page2['requirements'])
        detail = call('get_requirement', {'identifier': 'test-2'})['structuredContent']['requirement']
        assert detail['jiraKey'] == 'TEST-2' and detail['status'] == 'pending'
        history = call('get_requirement_history', {'identifier': detail['id']})['structuredContent']
        assert history['statusHistory'] and history['mergeRequests'] == []
        assert call('list_requirements', {'status': 'pending'})['structuredContent']['count'] == 12
        assert call('list_requirements', {'query': "' OR 1=1 --"})['structuredContent']['count'] == 0
        for args in [{'limit': 101}, {'offset': -1}, {'limit': True}, {'limit': 1.5}, {'status': 'bogus'}, {'sql': 'DROP TABLE requirements'}]:
            assert call('list_requirements', args)['isError'], args
        assert call('get_requirement', {'identifier': 'MISSING-1'})['isError']
        assert request(process, 'tools/call', {'name': 'update_requirement', 'arguments': {}})['error']['code'] == -32602
        assert request(process, 'unknown')['error']['code'] == -32601
        process.stdin.write('malformed\n'); process.stdin.flush()
        assert json.loads(process.stdout.readline())['error']['code'] == -32700
        assert request(process, 'ping')['result'] == {}
        # Fresh queries from the same MCP session see newly committed records.
        host(database, 'TEST-99')
        assert call('get_requirement_stats')['structuredContent']['total'] == 13
        process.stdin.close()
        assert process.wait(timeout=5) == 0
        assert process.stderr.read() == ''
    # A separate read-only session leaves the database bytes unchanged.
    before = hashlib.sha256(database.read_bytes()).hexdigest()
    with subprocess.Popen([str(bin_dir / 'RequirementTrackerMCP'), '--database', str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        initialize(process)
        request(process, 'tools/call', {'name': 'get_requirement_stats'})
        process.stdin.close(); assert process.wait(timeout=5) == 0
    assert hashlib.sha256(database.read_bytes()).hexdigest() == before
    absent = Path(folder) / 'absent.sqlite'
    with subprocess.Popen([str(bin_dir / 'RequirementTrackerMCP'), '--database', str(absent)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        initialize(process)
        assert request(process, 'tools/call', {'name': 'get_requirement_stats'})['result']['isError']
        process.stdin.close(); assert process.wait(timeout=5) == 0
    assert not absent.exists()
    def session_call(name, args=None):
        with subprocess.Popen([str(bin_dir / 'RequirementTrackerMCP'), '--database', str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
            initialize(process)
            response = request(process, 'tools/call', {'name': name, 'arguments': args or {}})['result']
            process.stdin.close()
            assert process.wait(timeout=5) == 0
            stderr = process.stderr.read()
            assert stderr == '', stderr
            return response

    def details(key='TEST-2'):
        return session_call('get_requirement', {'identifier': key})['structuredContent']

    def advance_args(key='TEST-2', **extra):
        result = details(key)
        return {'identifier': result['requirement']['id'], 'expected_revision': result['workflow']['revision'],
                'request_id': str(uuid.uuid4()), 'reason': '已完成当前阶段，验证结果通过', **extra}

    def execute_sql(sql, values=()):
        with sqlite3.connect(database) as connection:
            connection.execute(sql, values)

    def change_record(key, **changes):
        with sqlite3.connect(database) as connection:
            raw = json.loads(connection.execute('SELECT payload FROM requirements WHERE jira_key=?', (key,)).fetchone()[0])
            raw.update(changes)
            connection.execute('UPDATE requirements SET payload=? WHERE jira_key=?', (json.dumps(raw), key))

    assert not details()['workflow']['advancementEnabled']
    assert details()['workflow']['nextStatusTitle'] == '开发中'
    args = advance_args()
    assert session_call('advance_requirement', args)['isError']
    assert details()['requirement']['status'] == 'pending'
    execute_sql('UPDATE mcp_settings SET allow_advance=1')
    for overrides in [{'expected_revision': 'invalid'}, {'request_id': 'not-a-uuid'}, {'reason': ' '}, {'reason': True}, {'target_status': 'merged'}, {'merged_mr_url': 'https://git.example/a/-/merge_requests/1'}]:
        assert session_call('advance_requirement', {**args, **overrides})['isError'], overrides
    result = session_call('advance_requirement', args)['structuredContent']
    assert result['previousStatus'] == 'pending' and result['status'] == 'active' and not result['replayed']
    assert session_call('advance_requirement', args)['structuredContent']['replayed']
    assert session_call('advance_requirement', {**args, 'reason': 'changed'})['isError']
    assert session_call('advance_requirement', {**args, 'request_id': str(uuid.uuid4())})['isError']
    assert details()['requirement']['status'] == 'active'
    history = session_call('get_requirement_history', {'identifier': 'TEST-2'})['structuredContent']
    assert len(history['agentOperations']) == 1
    assert history['agentOperations'][0]['reason'] == args['reason']
    assert history['statusHistory'][-1]['status'] == 'active'

    # Even a metadata edit in the same second invalidates a previously read token.
    stale = advance_args()
    change_record('TEST-2', note='用户刚修改的备注', futureMetadata={'keep': True})
    assert session_call('advance_requirement', stale)['isError']
    assert session_call('advance_requirement', advance_args())['structuredContent']['status'] == 'done'
    assert session_call('advance_requirement', advance_args())['structuredContent']['status'] == 'tested'
    assert session_call('advance_requirement', advance_args())['isError']
    current_mr = 'https://git.example/project/-/merge_requests/42'
    change_record('TEST-2', mrURL=current_mr)
    assert session_call('advance_requirement', advance_args(merged_mr_url=current_mr + '0'))['isError']
    assert session_call('advance_requirement', advance_args(merged_mr_url=current_mr))['structuredContent']['status'] == 'merged'
    assert details()['workflow']['nextStatus'] is None
    assert session_call('advance_requirement', advance_args())['isError']
    with sqlite3.connect(database) as connection:
        raw = json.loads(connection.execute("SELECT payload FROM requirements WHERE jira_key='TEST-2'").fetchone()[0])
        assert raw['note'] == '用户刚修改的备注' and raw['futureMetadata'] == {'keep': True}
        assert connection.execute('SELECT count(*) FROM mcp_operations WHERE requirement_id=?', (raw['id'],)).fetchone()[0] == 4

    for key, stage in [('TEST-3', 'paused'), ('TEST-4', 'stopped')]:
        change_record(key, stage=stage)
        assert details(key)['workflow']['nextStatus'] is None
        assert session_call('advance_requirement', advance_args(key))['isError']
        assert details(key)['requirement']['status'] == stage

    # Independent processes using one observed revision may commit exactly once.
    common = advance_args('TEST-5')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: session_call('advance_requirement', {**common, 'request_id': str(uuid.uuid4())}), range(8)))
    assert sum(not result['isError'] for result in results) == 1
    assert details('TEST-5')['requirement']['status'] == 'active'
    repeated = advance_args('TEST-6')
    with concurrent.futures.ThreadPoolExecutor(max_workers=4) as pool:
        results = list(pool.map(lambda _: session_call('advance_requirement', repeated), range(8)))
    assert all(not result['isError'] for result in results)
    assert sum(not result['structuredContent']['replayed'] for result in results) == 1
    assert details('TEST-6')['requirement']['status'] == 'active'

    # Audit and state are one transaction: a failed audit insert must roll back state/history.
    before = details('TEST-7')
    execute_sql("CREATE TRIGGER fail_audit BEFORE INSERT ON mcp_operations BEGIN SELECT RAISE(ABORT, 'test audit failure'); END")
    assert session_call('advance_requirement', advance_args('TEST-7'))['isError']
    assert details('TEST-7') == before
    execute_sql('DROP TRIGGER fail_audit')

    # Permission revocation takes effect in an already initialized server.
    with subprocess.Popen([str(bin_dir / 'RequirementTrackerMCP'), '--database', str(database)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True) as process:
        initialize(process)
        fresh = advance_args('TEST-8')
        execute_sql('UPDATE mcp_settings SET allow_advance=0')
        assert request(process, 'tools/call', {'name': 'advance_requirement', 'arguments': fresh})['result']['isError']
        assert request(process, 'tools/call', {'name': 'get_requirement_stats'})['result']['structuredContent']['total'] == 13
        process.stdin.close(); assert process.wait(timeout=5) == 0
    # Upgrade an existing schema-1 database without touching its requirement payloads.
    with sqlite3.connect(database) as connection:
        prior = connection.execute('SELECT id,payload FROM requirements ORDER BY id').fetchall()
        connection.execute('DROP TABLE mcp_operations')
        connection.execute('DROP TABLE mcp_settings')
        connection.execute('PRAGMA user_version=1')
    assert not details()['workflow']['advancementEnabled']
    host(database, 'UPGRADE-1')
    with sqlite3.connect(database) as connection:
        assert connection.execute('PRAGMA user_version').fetchone()[0] == 2
        assert connection.execute('SELECT allow_advance FROM mcp_settings').fetchone()[0] == 0
        assert connection.execute("SELECT id,payload FROM requirements WHERE jira_key!='UPGRADE-1' ORDER BY id").fetchall() == prior
        assert connection.execute('PRAGMA integrity_check').fetchone()[0] == 'ok'
        assert connection.execute('PRAGMA foreign_key_check').fetchall() == []
print('MCP checks passed: 5 tools, readonly queries, next-step progression, audit rollback, merge gate, paused/stopped, stale edits, concurrent writes, idempotent retries, live permission revocation, schema upgrade')
