# SPIFlashLogger 2.2.0 #

The SPIFlashLogger library creates a circular log system which allows you to log any serializable object (table, array, string, blob, integer, float, boolean and `null`) to SPI flash connected to an imp. It works with either [**hardware.spiflash()**](https://developer.electricimp.com/api/hardware/spiflash) for SPI flash built into the imp003 or above, or any functionally compatible driver, such as the [SPIFlash library](https://developer.electricimp.com/libraries/hardware/spiflash), when working with the imp001 or imp002.

SPIFlashLogger uses the [Serializer library](https://developer.electricimp.com/libraries/utilities/serializer) or any other library for object serialization with an equivalent interface. Any libraries, used by the SPIFlashLogger must be added to your device code by `#require` statements (see the example under ‘Constructor’, below).

**Note** If the log system runs out of space in the SPI flash, it begins overwriting the oldest logs.

**To add this library to your project, place the line** `#require "SPIFlashLogger.device.lib.nut:2.2.0"` **at the top of your device code.**

## Memory Efficiency ##

SPIFlashLogger operates on 4KB sectors and 256-byte chunks. Objects need not be aligned with chunks or sectors. Some necessary overhead is added to the beginning of each sector, as well as each serialized object (assuming you are using the standard [Serializer library](https://developer.electricimp.com/libraries/utilities/serializer)). The overhead includes:

- Six bytes of every sector are expended on sector-level metadata.
- A four-byte marker is added to the beginning of each serialized object to aid in locating objects in the datastream.
- The *Serializer* object also adds some overhead to each object (see the [Serializer’s documentation](https://developer.electricimp.com/libraries/utilities/serializer) for more information).
- After a reboot the sector metadata allows the class to locate the next write position at the next chunk. This wastes some of the previous chunk, though this behaviour can be overridden using the *getPosition()* and *setPosition()* methods.

## Class Usage ##

### Constructor: SPIFlashLogger(*[start][, end][, spiflash][, serializer]*) ###

SPIFlashLogger’s constructor takes four parameters, all of which are optional:

| Parameter | Default Value | Description |
| --- | --- | --- |
| *start* | 0 | The first byte in the SPI flash to use (must be the first byte of a sector) |
| *end*  | *spiflash.size()* | The last byte in the SPI flash to use (must be the last byte of a sector) |
| *spiflash*  | **hardware.spiflash** | **hardware.spiflash**, or an object with an equivalent interface such as the [SPIFlash](https://electricimp.com/docs/libraries/hardware/spiflash) library |
| *serializer* | Serializer class | The static [Serializer library](https://developer.electricimp.com/libraries/hardware/spiflash), or an object with an equivalent interface |

```squirrel
// Initializing a SPIFlashLogger on an imp003+
#require "Serializer.class.nut:1.0.0"
#require "SPIFlashLogger.device.lib.nut:2.2.0"

// Initialize Logger to use the entire SPI Flash
logger <- SPIFlashLogger();
```

```squirrel
// Initializing a SPIFlashLogger on an imp002
#require "Serializer.class.nut:1.0.0"
#require "SPIFlash.class.nut:1.0.1"
#require "SPIFlashLogger.device.lib.nut:2.2.0"

// Setup SPI Bus
spi <- hardware.spi257;
spi.configure(CLOCK_IDLE_LOW | MSB_FIRST, 30000);

// Setup Chip Select Pin
cs <- hardware.pin8;
spiFlash <- SPIFlash(spi, cs);

// Initialize the logger object using the entire SPIFlash
logger <- SPIFlashLogger(null, null, spiFlash);
```

## Class Methods ##

### dimensions() ###

This method returns a table with the following keys, each of which gives access to an integer value:

| Key | Description |
| --- | --- |
| *size* | The size of the SPI flash in bytes |
| *len* | The number of bytes allocated to the logger |
| *start* | The first byte used by the logger |
| *end* | The last byte used by the logger |
| *sectors* | The number of sectors allocated to the logger |
| *sectorSize* | The size of sectors in bytes |

### write(*object*) ###

This method writes any serializable object to the memory allocated for SPIFlashLogger. If the memory is full, the logger begins overwriting the oldest entries.

If the provided object can not be serialized, the exception is thrown by the underlying serializer class.

```squirrel
function readAndSleep() {
    // Read and log the data
    local data = getData();
    logger.write(data);

    // Go to sleep for an hour
    imp.onidle(function() { server.deepsleepfor(3600); });
}
```

### read(*onData[, onFinish][, step][, skip]*) ###

This method reads objects from the logger asynchronously. This mechanism is intended for the asynchronous processing of each log object, such as sending data to the agent and waiting for an acknowledgement.

| Parameter | Data Type | Required? | Description |
| --- | --- | --- | --- |
| *onData* | Function | Yes | A callback which provides the object which has been read from the logger (see below) |
| *onFinish* | Function | No | A callback which is called after the last object is provided (ie. there are no more objects to return by the current *read()* operation), when the operation it terminated, or in case of an error. The callback has no parameters |
| *step* | Integer | No | The rate at which the read operation steps through the logged objects. Must not be 0. If it has a positive value, the read operation starts from the oldest logged object. If it has a negative value, the read operation starts from the most recently written object and steps backwards. Default: 1 |
| *skip* | Integer | No | Skips the specified number of the logged objects at the start of the reading. Must not be negative. default: 0 |

The *onData* callback has the following signature: *ondata(object, address, next)*

| Parameter | Data Type | Description |
| ---| --- | --- |
| *object* | Any | Deserialized log object returned by the read operation |
| *address* | Number | The object’s start address in the SPI flash |
| *next* | Function | A callback function to iterate the next logged object. Your application should call it either to continue the read operation or to terminate it. It has one optional, boolean parameter: specify `true` (the default) to continue the read operation and ask for the next logged object, or `false` to terminate the read operation (in this case the *onFinish* callback will be called immediately) |

**Note** It is safe to call and process several read operations in parallel.

The *step* and *skip* parameters are introduced to provide a full coverage of possible use cases. For example:
- `step == 2, skip == 0`: *onData* to be called for every second object only, starting from the oldest logged object.
- `step == 2, skip == 1`: *onData* to be called for every second object only, starting from the second oldest logged object.
- `step == -1, skip == 0`: *onData* to be called for every object, starting from the most recently written object and steps backwards.
- `step == -2, skip == 1`: *onData* to be called for every second object only, starting from the second most recently written object and steps backwards.

As a potential use case, one might log two versions of each message: a short, concise version, and a longer, more detailed version. `step == 2` could then be used to pick up only the concise versions.

**Note** The logger does not erase objects when they are read, but each object can be erased in the *onData* callback by passing *address* to the *erase()* method.

```squirrel
logger.read(
    // For each object in the logs (onData)
    function(dataPoint, address, next) {
        // Send the dataPoint to the agent
        server.log(format("Found object at SPI flash address %d", address))
        agent.send("data", dataPoint);
        // Erase it from the logger
        logger.erase(address);
        // Wait a little while for it to arrive
        imp.wakeup(0.5, next);
    },

    // All finished (onFinish)(
    function() {
        server.log("Finished sending and all entries are erased")
    }
);
```

### readSync(*index*) ###

This method reads objects from the logger synchronously, returning a single log object for the specified *index*.

*readSync()* returns:
- The most recent object when *index* is -1.
- The oldest object when *index* is 1.
- `null` when the value of *index* is greater than the number of logs.
- Throws an exception when *index* is 0.

*readSync*() starts from the current logger position, which is equal to the current write position. Therefore `readSync(0)` could not contain any object, and `readSync(-1)` is equal to ‘step back to read the last written object’. If the value of *index* is greater than zero, the logger is looking for an object in a first populated sector right after the current logger position, or it will read the beginning of the sector at the current position if there are no more sectors with objects.

```squirrel
logger <- SPIFlashLogger(0, 16384);

local microsAtStart = hardware.micros();
for (local i = 0 ; i <= 1500 ; i++) {
    logger.write(i)
}

server.log("Writing took " + (hardware.micros() - microsAtStart) / 1000000.0 + " seconds");

microsAtStart = hardware.micros();
server.log("First = " + logger.first() + " in " + (hardware.micros() - microsAtStart) + " μs")

microsAtStart = hardware.micros();
server.log("Last  = " + logger.last()  + " in " + (hardware.micros() - microsAtStart) + " μs");

microsAtStart = hardware.micros();
server.log("Index 200 = " + logger.readSync(200)  + " in " + (hardware.micros() - microsAtStart) + " μs");

microsAtStart = hardware.micros();
server.log("Index 1178 = " + logger.readSync(1178)  + " in " + (hardware.micros() - microsAtStart) + " μs");
```

### first(*[default]*) ###

This method synchronously returns the first object written to the log that hasn’t yet been erased (ie. the oldest entry in flash). If there are no logs in the flash, it returns *default*, or `null` if no argument is passed into *default*.

```squirrel
logger.write("This is the oldest");
logger.write("This is the newest");
assert(logger.first() == "This is the oldest");
```

### last(*[default]*) ### 

This method synchronously returns the last object written to the log that hasn’t yet been erased (ie. the newest entry in flash). If there are no logs in the flash, it returns *default*, or `null` if no argument is passed into *default*.

```squirrel
logger.eraseAll();
assert(logger.last("Test Default value") == "Test Default value");
logger.write("Now this is the oldest message on the flash");
assert(logger.last(Test Default value") == "Now this is the oldest message on the flash");
```

### erase(*[address]*) ###

This method erases an object at the SPI flash *address* by marking it erased. If *address* is not specified, it behaves as the *eraseAll()* method with the default parameter.

### eraseAll(*[force]*) ###

This method erases the entire allocated SPI flash area. The optional *force* parameter is a Boolean value which defaults to `false`, a value which will cause the method to erase only the sectors written to by this library. You **must** pass in `true` if you wish to erase the entire allocated SPI flash area.

### getPosition() ###

This method returns the current SPI flash pointer, ie. where SPIFlashLogger will perform the next read/write task. This information can be used along with the *setPosition()* method to optimize SPI flash memory usage between deep sleeps.

See *setPosition()* for sample usage.

### setPosition(*position*)###

This method sets the current SPI flash pointer, ie. where SPIFlashLogger will perform the next read/write task. Setting the pointer can help optimize SPI flash memory usage between deep sleeps, as it allows SPIFlashLogger to be precise to one byte rather 256 bytes (the size of a chunk).

```squirrel
// Create the logger object
logger <- SPIFlashLogger();

// Check if we have position information in the nv table:
if ("nv" in getroottable() && "position" in nv) {
    // If we do, update the position pointers in the logger object
    logger.setPosition(nv.position);
} else {
    // If we don't, grab the position points and set nv
    local position = logger.getPosition();
    nv <- { "position": position };
}

// Get some data and log it
data <- getData();
logger.write(data);

// Increment a counter
if (!("count" in nv)) {
    nv.count <- 1;
} else {
    nv.count++;
}

// If we have more than 100 samples
if (nv.count > 100) {
    // Send the samples to the agent
    logger.read(
        function(dataPoint, addr, next) {
            // Send the dataPoint to the agent
            agent.send("data", dataPoint);
            // Erase it from the logger
            logger.erase(addr);
            // Wait a little while for it to arrive
            imp.wakeup(0.5, next);
        },
        function() {
            server.log("Finished sending and all entries are erased");
            // Reset counter
            nv.count <- 1;
            // Go to sleep when done
            imp.onidle(function() {
                // Get and store position pointers for next run
                local position = logger.getPosition();
                nv.position <- position;

                // Sleep for 1 minute
                imp.deepsleepfor(60);
            });
        }
    );
} else {
    // Go to sleep
    imp.onidle(function() {
        // Get and store position pointers for next run
        local position = logger.getPosition();
        nv.position <- position;

        // Sleep for 1 minute
        imp.deepsleepfor(60);
    });
}
```

# License

The SPIFlashLogger library is licensed under [MIT License](https://github.com/electricimp/spiflashlogger/tree/master/LICENSE).
