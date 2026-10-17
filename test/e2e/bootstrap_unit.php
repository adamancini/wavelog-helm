<?php
// Unit checks for bootstrap.php helpers. Runs inside the Wavelog image (the only
// place with PHP): php bootstrap_unit.php <path-to-bootstrap.php>
define('WL_BOOTSTRAP_NO_MAIN', true);
require $argv[1];

$failures = 0;
function check(bool $ok, string $name): void
{
    global $failures;
    echo ($ok ? 'ok: ' : 'FAIL: ') . $name . "\n";
    $failures += $ok ? 0 : 1;
}

// Run fill_template in a child process; returns [exit code, stderr].
function fill_in_child(string $tpl, array $values): array
{
    $code = 'define("WL_BOOTSTRAP_NO_MAIN", true); require $argv[1];'
        . ' fill_template(base64_decode($argv[2]), json_decode(base64_decode($argv[3]), true));';
    $p = proc_open(
        ['php', '-r', $code, '--', $GLOBALS['argv'][1], base64_encode($tpl), base64_encode(json_encode($values))],
        [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes
    );
    stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    return [proc_close($p), $err];
}

// Values that look like placeholders are substituted verbatim, never rescanned.
$tpl = "<?php\n\$config['a'] = '%a%';\n\$config['b'] = '%b%';\n\$config['n'] = '%n%';\n";
$values = ['a' => '%b%', 'b' => "'%a%' \"\$x\" \\ end", 'n' => 7];
$out = fill_template($tpl, $values);
$file = tempnam(sys_get_temp_dir(), 'tpl');
file_put_contents($file, $out);
$config = [];
include $file;
unlink($file);
check($config === $values, 'placeholder-like and special-character values round-trip');

[$rc, $err] = fill_in_child("x = '%a%';", ['a' => '1', 'b' => '2']);
check($rc !== 0 && str_contains($err, "placeholder '%b%' not found"), 'value without placeholder fails');

[$rc, $err] = fill_in_child("x = '%a%'; y = '%c%';", ['a' => '1']);
check($rc !== 0 && str_contains($err, "unfilled placeholder '%c%'"), 'template placeholder without value fails');

// Run $code (with bootstrap.php loaded) in a child process with extra env vars;
// returns [exit code, stdout, stderr].
function run_in_child(string $code, array $env): array
{
    $p = proc_open(
        ['php', '-r', 'define("WL_BOOTSTRAP_NO_MAIN", true); require $argv[1]; ' . $code, '--', $GLOBALS['argv'][1]],
        [1 => ['pipe', 'w'], 2 => ['pipe', 'w']],
        $pipes,
        null,
        array_merge(getenv(), $env)
    );
    $out = stream_get_contents($pipes[1]);
    $err = stream_get_contents($pipes[2]);
    return [proc_close($p), $out, $err];
}

// Load a rendered config file the way CodeIgniter does.
function load_config(string $file): array
{
    if (!defined('BASEPATH')) {
        define('BASEPATH', '/');
    }
    $config = [];
    include $file;
    return $config;
}

// render_sso: upstream's sample with auth.header values set in place.
$dir = sys_get_temp_dir() . '/sso-' . getmypid();
mkdir($dir);
$sso = [
    'jwksUri' => 'http://idp.example.com/jwks.json',
    'headerName' => 'HTTP_X_FORWARDED_ACCESS_TOKEN',
    'createUsers' => false,
    'allowDirectLogin' => true,
    'hidePasswordField' => false,
    'buttonText' => "Log in with 'SSO' \"\$x\"",
    'logoutUrl' => '',
    'extra' => [
        'auth_header_debug_jwt' => true,
        'auth_headers_claim_config' => ['user_name' => ['claim' => 'sub', 'override_on_update' => false, 'allow_manual_change' => false]],
    ],
];
[$rc, , $err] = run_in_child('render_sso();', ['WL_CONFIG_DIR' => $dir, 'WL_SSO_JSON' => json_encode($sso)]);
check($rc === 0, "render_sso succeeds $err");
$config = load_config("$dir/sso.php");
check($config['auth_header_jwks_uri'] === 'http://idp.example.com/jwks.json', 'jwksUri -> auth_header_jwks_uri');
check($config['auth_header_accesstoken'] === 'HTTP_X_FORWARDED_ACCESS_TOKEN', 'headerName -> auth_header_accesstoken');
check($config['auth_header_create'] === false, 'createUsers -> auth_header_create (sample default true)');
check($config['auth_header_allow_direct_login'] === true, 'allowDirectLogin -> auth_header_allow_direct_login (sample default false)');
check($config['auth_header_hide_password_field'] === false, 'hidePasswordField -> auth_header_hide_password_field (sample default true)');
check($config['auth_header_text'] === $sso['buttonText'], 'buttonText -> auth_header_text with special characters');
check($config['auth_header_url_logout'] === '', 'logoutUrl -> auth_header_url_logout');
check($config['auth_header_debug_jwt'] === true, 'extra overrides a sample key');
check($config['auth_headers_claim_config'] === $sso['extra']['auth_headers_claim_config'], 'extra map written verbatim');
check($config['auth_header_clubstation_direct'] === [], 'untouched sample keys kept');
check(preg_match_all("/^\\\$config\\['auth_header_jwks_uri'\\]/m", file_get_contents("$dir/sso.php")) === 1, 'jwks uri assigned once');
unlink("$dir/sso.php");

// Without an extra claim map, the sample's name claims stay but become editable:
// Wavelog requires both names to save the account form.
[$rc, , $err] = run_in_child('render_sso();', ['WL_CONFIG_DIR' => $dir, 'WL_SSO_JSON' => '{"jwksUri":"http://idp.example.com/jwks.json"}']);
check($rc === 0, "render_sso succeeds without extra $err");
$claims = load_config("$dir/sso.php")['auth_headers_claim_config'];
foreach (['user_firstname' => 'given_name', 'user_lastname' => 'family_name'] as $field => $claim) {
    check(
        $claims[$field] === ['claim' => $claim, 'override_on_update' => true, 'allow_manual_change' => true],
        "$field keeps claim $claim and is editable"
    );
}
check($claims['user_callsign']['allow_manual_change'] === false, 'other sample claims stay locked');
unlink("$dir/sso.php");

[$rc, , $err] = run_in_child('render_sso();', ['WL_CONFIG_DIR' => $dir, 'WL_SSO_JSON' => '{"jwksUri":""}']);
check($rc !== 0 && str_contains($err, 'bootstrap: auth.header.jwksUri is required when auth.mode=header'), 'render_sso requires jwksUri');
foreach (['auth_header_jwks_uri', 'auth_header_create'] as $mappedKey) {
    $bad = ['jwksUri' => 'http://idp.example.com/jwks.json', 'extra' => [$mappedKey => '']];
    [$rc, , $err] = run_in_child('render_sso();', ['WL_CONFIG_DIR' => $dir, 'WL_SSO_JSON' => json_encode($bad)]);
    check(
        $rc !== 0 && str_contains($err, "bootstrap: auth.header.extra must not set $mappedKey; use the dedicated auth.header value")
            && !file_exists("$dir/sso.php"),
        "extra cannot override $mappedKey"
    );
}
rmdir($dir);

// api_keys_from_env: trimmed, non-empty, at most 255 chars, unique.
[$rc, $out] = run_in_child('echo json_encode(api_keys_from_env(2));', ['WL_API_KEY_0' => "  key0\n", 'WL_API_KEY_1' => "key1\r\n"]);
check($rc === 0 && $out === '["key0","key1"]', 'api keys are trimmed');
[$rc, , $err] = run_in_child('api_keys_from_env(1);', ['WL_API_KEY_0' => " \n"]);
check($rc !== 0 && str_contains($err, 'bootstrap: apiKeys[0]: key is empty'), 'whitespace-only api key fails');
[$rc, , $err] = run_in_child('api_keys_from_env(1);', ['WL_API_KEY_0' => str_repeat('k', 256)]);
check($rc !== 0 && str_contains($err, 'bootstrap: apiKeys[0]: key is longer than 255 characters'), 'over-long api key fails');
[$rc] = run_in_child('api_keys_from_env(1);', ['WL_API_KEY_0' => str_repeat('k', 255)]);
check($rc === 0, '255-character api key accepted');
[$rc, , $err] = run_in_child('api_keys_from_env(2);', ['WL_API_KEY_0' => 'same', 'WL_API_KEY_1' => "same\n"]);
check($rc !== 0 && str_contains($err, 'bootstrap: apiKeys[1]: same key as apiKeys[0]'), 'duplicate api key fails');

exit($failures === 0 ? 0 : 1);
