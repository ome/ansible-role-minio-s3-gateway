import json
import os
import random
from string import ascii_lowercase
import testinfra.utils.ansible_runner

testinfra_hosts = testinfra.utils.ansible_runner.AnsibleRunner(
    os.environ['MOLECULE_INVENTORY_FILE']).get_hosts('all')


def check_mc_json_output(s, status='success'):
    # minio outputs one json object per line, NOT an array
    objects = [json.loads(line) for line in s.splitlines()]
    for o in objects:
        assert o['status'] == status
    return objects


def add_user(host):
    # Adds a user, creates a config file under /tmp/mc-{username}
    # with alias test-s3
    out = host.check_output(
        'sh -c "mc ls minio-s3-gateway/test || '
        'mc mb minio-s3-gateway/test"')
    username = ''.join(random.choice(ascii_lowercase) for i in range(8))
    out = host.check_output('minio-user.sh add %s', username)
    lines = out.splitlines()
    assert lines[-2] == f'Access token: {username}'
    assert lines[-1].startswith('Secret token: ')
    secret = lines[-1][14:]
    assert len(secret) == 30

    configdir = f'/tmp/mc-{username}'
    host.check_output(
        f'mc -C {configdir} config host add test-s3 '
        f'http://localhost:9000 {username} {secret}')

    return username, secret, configdir


def test_user_add(host):
    username, secret, configdir = add_user(host)
    out = host.check_output(
        f'mc ls --json minio-s3-gateway/test/{username}/')
    ls_as_root = check_mc_json_output(out)
    assert len(ls_as_root) == 1
    assert ls_as_root[0]['key'] == 'README.txt'


def test_user_list(host):
    username, secret, configdir = add_user(host)
    out = host.check_output(
        f'mc -C {configdir} ls --json test-s3/test/{username}/')
    ls = check_mc_json_output(out)
    assert len(ls) == 1
    assert ls[0]['key'] == 'README.txt'


def test_user_read(host):
    username, secret, configdir = add_user(host)
    out = host.check_output(
        f'mc -C {configdir} cat test-s3/test/{username}/README.txt')
    assert out == 'Hello!'


def test_user_write(host):
    username, secret, configdir = add_user(host)
    out = host.check_output(
        f'mc -C {configdir} cp '
        f'test-s3/test/{username}/README.txt '
        f'test-s3/test/{username}/copied.txt')
    out = host.check_output(
        f'mc -C {configdir} cat test-s3/test/{username}/copied.txt')
    assert out == 'Hello!'


def test_user_no_access_bucket(host):
    username, secret, configdir = add_user(host)
    out = host.run(
        f'mc -C {configdir} ls --json test-s3/test/')
    assert out.rc > 0
    ls = check_mc_json_output(out.stdout, 'error')
    assert ls[0]['error']['cause']['error']['Code'] == 'AccessDenied'


def test_user_no_access_other(host):
    username, secret, configdir = add_user(host)
    user2, secret2, configdir2 = add_user(host)

    out2 = host.run(
        f'mc -C {configdir2} ls --json test-s3/test/{user2}/')
    assert out2.rc == 0

    out = host.run(
        f'mc -C {configdir} ls --json test-s3/test/{user2}/')
    assert out.rc > 0
    ls = check_mc_json_output(out.stdout, 'error')
    assert ls[0]['error']['cause']['error']['Code'] == 'AccessDenied'

    out2 = host.run(
        f'mc -C {configdir2} cat test-s3/test/{user2}/README.txt')
    assert out2.rc == 0

    out = host.run(
        f'mc -C {configdir} cat test-s3/test/{user2}/README.txt')
    assert out.rc > 0
    assert 'ERROR' in out.stderr
