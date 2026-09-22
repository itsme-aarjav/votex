const fs = require('fs');
const path = require('path');
const assert = require('assert');

function runTests() {
  console.log('--- Running Votex Result Dashboard Integration Tests ---');

  // Test 1: Port environment configuration
  const port = process.env.PORT || 80;
  assert(Number(port) > 0, 'Port must be a positive integer');
  console.log('✓ Port environment configuration valid');

  // Test 2: Views existence and Votex brand check
  const indexPath = path.join(__dirname, '..', 'views', 'index.html');
  assert(fs.existsSync(indexPath), 'views/index.html must exist');
  const content = fs.readFileSync(indexPath, 'utf8');
  assert(content.includes('Votex'), 'views/index.html must contain Votex branding');
  console.log('✓ views/index.html verified with Votex branding');

  // Test 3: Static stylesheets check
  const cssPath = path.join(__dirname, '..', 'views', 'stylesheets', 'style.css');
  assert(fs.existsSync(cssPath), 'stylesheets/style.css must exist');
  console.log('✓ stylesheets/style.css verified');

  console.log('All Result dashboard integration tests passed successfully!');
}

// Support both Jest and standalone node execution
if (typeof describe !== 'undefined') {
  describe('Votex Result Dashboard Integration Tests', () => {
    test('Runs all verification checks', () => {
      runTests();
    });
  });
} else {
  runTests();
}
