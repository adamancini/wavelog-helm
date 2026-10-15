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

exit($failures === 0 ? 0 : 1);
