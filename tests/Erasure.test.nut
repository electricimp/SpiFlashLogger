class TestErasure extends ImpTestCase {
    _logger = null;

    function setUp() {
        // Do some wear leveling
        local s = math.rand() % 120;
        local e = s + 1; // Assign only one sector
        s*= SPIFLASHLOGGER_SECTOR_SIZE;
        e*= SPIFLASHLOGGER_SECTOR_SIZE;

        _logger = SPIFlashLogger(s, e);
        _logger.erase() // start fresh

        _logger.write(1);
        _logger.write(2);
        _logger.write(3);
        _logger.write(4);
        _logger.write(5);
    }

    // Begin tests

    function testReadEraseRead() {
        return Promise( function(resolve, reject) {
            local expected = 1;

            local checkOne = function(data, addr, next) {
                this.assertEqual(expected, data);
                expected += 1;
                // Erase entries as they're read
                _logger.erase(addr);
                next();
            }.bindenv(this);

            // Read all entries
            _logger.read(checkOne, resolve);
        }.bindenv(this))

        .then( function(_) {
            return Promise( function(resolve, reject) {

                local checkOne = function(data, addr, next) {
                    this.assertTrue(false);
                }.bindenv(this);

                // Read all entries again (should be none)
                _logger.read(checkOne, resolve);

            }.bindenv(this));
        })
    }
}
