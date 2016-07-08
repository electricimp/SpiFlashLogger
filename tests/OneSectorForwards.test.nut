class TestOneSectorForward extends ImpTestCase {
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

    function testReadOrder() {
        return Promise( function(resolve, reject) {
            local expected = 1;
            local checkOne = function(data, addr, next) {
                this.assertEqual(expected, data);
                expected += 1;
                next();
            }.bindenv(this);
            _logger.read(checkOne, resolve);
        }.bindenv(this));
    }

    function testByTwos() {
        return Promise( function(resolve, reject) {
            local expected = 1;
            local checkOne = function(data, addr, next) {
                this.assertEqual(expected, data);
                expected += 2;
                next();
            }.bindenv(this);
            _logger.read(checkOne, resolve, 2);
        }.bindenv(this));
    }

    function testByTwosPlusOne() {
        return Promise( function(resolve, reject) {
            local expected = 2;
            local checkOne = function(data, addr, next) {
                this.assertEqual(expected, data);
                expected += 2;
                next();
            }.bindenv(this);
            _logger.read(checkOne, resolve, 2, 1);
        }.bindenv(this));
    }

    function testByThrees() {
        return Promise( function(resolve, reject) {

            local expected = 1;

            local checkOne = function(data, addr, next) {
                this.assertEqual(expected, data);
                expected += 3;
                next();
            }.bindenv(this);

            _logger.read(checkOne, resolve, 3);

        }.bindenv(this));
    }

}
