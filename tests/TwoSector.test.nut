class TestTwoSector extends ImpTestCase {
    _logger = null;

    function setUp() {
        // Do some wear leveling
        local s = math.rand() % 120;
        local e = s + 2; // Assign two sectors
        s*= SPIFLASHLOGGER_SECTOR_SIZE;
        e*= SPIFLASHLOGGER_SECTOR_SIZE;

        _logger = SPIFlashLogger(s, e);
        _logger.erase() // start fresh

        for (local i = 0; i < 500; i++) {
            _logger.write(i);
        }

    }

    // Begin tests

    function testReadForwards() {
        return Promise( function(resolve, reject) {
            local expected = 0;
            local checkOne = function(data, addr, next) {
                /* server.log(format("found %d at %d", data, addr)); */
                this.assertEqual(expected, data);
                expected += 1;
                next();
            }.bindenv(this);
            _logger.read(checkOne, resolve);
        }.bindenv(this));
    }

    function testReadBackwards() {
        return Promise( function(resolve, reject) {
            local expected = 499;
            local checkOne = function(data, addr, next) {
                /* server.log(format("found %d at %d", data, addr)) */
                this.assertEqual(expected, data);
                expected -= 1;
                next();
            }.bindenv(this);
            _logger.read(checkOne, resolve, -1);
        }.bindenv(this));
    }

}
