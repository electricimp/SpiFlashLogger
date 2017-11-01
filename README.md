# SPIFlashLogger 2.2.0

This is a library for IMP device.

The SPIFlashLogger creates a circular log system, allowing you to log any serializable object (table, array, string, blob, integer, float, boolean and `null`) to the SPIFlash. If the log system runs out of space in the SPIFlash, it begins overwriting the oldest logs.

The SPIFlashLogger works either via the [hardware.spiflash](https://electricimp.com/docs/api/hardware/spiflash) (built-in the imp003 or above) or any functionally compatible driver such as the [SPIFlash library](https://electricimp.com/docs/libraries/hardware/spiflash) (available for the imp001 and imp002).

The SPIFlashLogger uses either the [Serializer library](https://electricimp.com/docs/libraries/utilities/serializer) or any other library for objects serialization with an equivalent interface.

The libraries, used by the SPIFlashLogger in your case, must be added to your device code by `#require` statements.

**To add SPIFlashLogger library to your project, add** `#require "SPIFlashLogger.class.nut:2.2.0"` **to the top of your device code.**

## Memory Efficiency

The SPIFlash logger operates on 4KB sectors and 256-byte chunks. Objects needn't be aligned with chunks or sectors.  Some necessary overhead is added to the beginning of each sector, as well as each serialized object (assuming you are using the standard [Serializer library](https://electricimp.com/docs/libraries/utilities/serializer)). The overhead includes:

- Six bytes of every sector are expended on sector-level metadata.
- A four-byte marker is added to the beginning of each serialized object to aid in locating objects in the datastream.
- The *Serializer* object also adds some overhead to each object (see the [Serializer's documentation](https://electricimp.com/docs/libraries/utilities/serializer) for more information).
- After a reboot the sector metadata allows the class to locate the next write position at the next chunk. This wastes some of the previous chunk, though this behaviour can be overridden using the *getPosition()* and *setPosition()* methods.

## Class Usage

### Constructor: SPIFlashLogger(*[start][, end][, spiflash][, serializer]*)

The SPIFlashLogger’s constructor takes four parameters, all of which are optional:

| Parameter | Default Value | Description |
| --- | --- | --- |
| *start* | 0 | The first byte in the SPIFlash to use (must be the first byte of a sector). |
| *end*  | *spiflash.size()*   | The last byte in the SPIFlash to use (must be the last byte of a sector). |
| *spiflash*  | **hardware.spiflash** | hardware.spiflash, or an object with an equivalent interface such as the [SPIFlash](https://electricimp.com/docs/libraries/hardware/spiflash) library. |
| *serializer* | Serializer class | The static [Serializer library](https://electricimp.com/docs/libraries/utilities/serializer), or an object with an equivalent interface. |

```squirrel
// Initializing a SPIFlashLogger on an imp003+
#require "Serializer.class.nut:1.0.0"
#require "SPIFlashLogger.class.nut:2.2.0"

// Initialize Logger to use the entire SPI Flash
logger <- SPIFlashLogger();
```

```squirrel
// Initializing a SPIFlashLogger on an imp002
#require "Serializer.class.nut:1.0.0"
#require "SPIFlash.class.nut:1.0.1"
#require "SPIFlashLogger.class.nut:2.2.0"

// Setup SPI Bus
spi <- hardware.spi257;
spi.configure(CLOCK_IDLE_LOW | MSB_FIRST, 30000);

// Setup Chip Select Pin
cs <- hardware.pin8;
spiFlash <- SPIFlash(spi, cs);

// Initialize the logger object using the entire SPIFlash
logger <- SPIFlashLogger(null, null, spiFlash);
```

## Class Methods

### dimensions()

The *dimensions()* method returns a table with the following keys, each of which gives access to an integer value:

| Key | Description |
| --- | --- |
| *size* | The size of the SPIFlash in bytes |
| *len* | The number of bytes allocated to the logger |
| *start* | The first byte used by the logger |
| *end* | The last byte used by the logger |
| *sectors* | The number of sectors allocated to the logger |
| *sectorSize* | The size of sectors in bytes |

### write(*object*)

Writes any serializable object to the memory allocated for the SPIFlashLogger. If the memory is full, the logger begins overwriting the oldest entries.
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

### read(*onData\[, onFinish]\[, step]\[, skip]*)

Reads objects from the logger asynchronously.

This mehanism is intended for the asynchronous processing of each log object, such as sending data to the agent and waiting for an acknowledgement.

| Parameter 	| Data Type | Required? | Description |
| ------------- | --------- | --------- | ----------- |
| onData        | Function  |    yes    | Callback that provides the object which has been read from the logger. See below. |
| onFinish      | Function  |    no     | Callback that is called after the last object is provided (i.e. there are no more objects to return by the current *read* operation), or when the operation it terminated, or in case of an error The callback has no parameters. |
| step          | Number    |    no     | The rate at which the read operation steps through the logged objects. Must not be 0. If it has a positive value the read operation starts from the oldest logged object. If it has a negative value, the read operation starts from the most recently written object and steps backwards. By default : 1 |
| skip          | Number    |    no     | Skips the specified number of the logged objects at the start of the reading. Must not has a negative value. By default: 0 |

*onData* callback has the following signature:  **ondata(object, address, next)**, where

| Parameter 	| Data Type | Description |
| ------------- | --------- | ----------- |
| object        | Any       | Deserialized log object returned by the read operation. |
| address       | Number    | The object's start address in the SPIFlash. |
| next          | Function  | Callback function to iterate the next logged object. Your application should call it either to continue the read operation or to terminate it. It has one optional boolean parameter: specify `true` (default value) to continue the read operation and ask for the next logged object, specify `false` to terminate the read operation (in this case *onFinish* callback will be called immediately). |

**Note**, It is safe to call and process several read operations in parallel.

*step* and *skip* parameters are introduced to provide a full coverage of possible use cases. For example:
- `step == 2, skip == 0`: *onData* to be called for every second object only, starting from the oldest logged object.
- `step == 2, skip == 1`: *onData* to be called for every second object only, starting from the second oldest logged object.
- `step == -1, skip == 0`: *onData* to be called for every object, starting from the most recently written object and steps backwards.
- `step == -2, skip == 1`: *onData* to be called for every second object only, starting from the second most recently written object and steps backwards.

As a potential use case, one might log two versions of each message: a short, concise version, and a longer, more detailed version. `step == 2` could then be used to pick up only the concise versions.

**Note**, the logger does not erase object on reading but each object can be erased in the *onData* callback by passing *address* to the *erase()* method.

```squirrel
logger.read(
    // For each object in the logs
    function(dataPoint, addr, next) {
        // Send the dataPoint to the agent
        server.log(format("Found object at spiflash address %d", addr))
        agent.send("data", dataPoint);
        // Erase it from the logger
        logger.erase(addr);
        // Wait a little while for it to arrive
        imp.wakeup(0.5, next);
    },

    // All finished
    function() {
        server.log("Finished sending and all entries are erased")
    }
);
```
### readSync(*index*)

Reads objects from the logger synchronously, returning a single log object for the specified *index*.

*readSync()* returns:
- the most recent object when `index == -1`,
- the oldest object when `index == 1`,
- *null* when the value of *index* is greater than the number of logs,
- throws an exception when `index == 0`.

*readSync*() is like a sync version of *read()*. It starts from the current logger position, which is equal to the current write position, therefore `index == 0` could not contain any object and `index == -1` is equal to step back to read the last written object.
For the `index > 0` logger is looking for an object in a first not free sector right after the current logger position or read the beginning of the sector at the current position if there is no more sectors with objects.

 ```squirrel
 logger <- SPIFlashLogger(0, 4096 * 4);

 local microsAtStart = hardware.micros()
 for(local i = 0; i <= 1500; i++)
     logger.write(i)

 server.log("Writing took " + (hardware.micros() - microsAtStart) / 1000000.0 + " sec")

 microsAtStart = hardware.micros()
 server.log("first = " + logger.first() + " in " + (hardware.micros() - microsAtStart) + " μs")

 microsAtStart = hardware.micros()
 server.log("last  = " + logger.last()  + " in " + (hardware.micros() - microsAtStart) + " μs")

 microsAtStart = hardware.micros()
 server.log("Index 200 = " + logger.readSync(200)  + " in " + (hardware.micros() - microsAtStart) + " μs")

 microsAtStart = hardware.micros()
 server.log("Index 1178 = " + logger.readSync(1178)  + " in " + (hardware.micros() - microsAtStart) + " μs")

 ```

 ### first(*[default = null]*)

 Synchronously returns the first object written to the log that hasn't been erased (i.e. the oldest entry on flash).  If there are no logs on the flash, returns *default*.

 ```squirrel
 logger.write("This is the oldest")
 logger.write("This is the newest")
 assert(logger.first() == "This is the oldest");
 ```

 ### last(*[default = null]*)

 Synchronously returns the last object written to the log that hasn't been erased (i.e. the newest entry on flash). If there are no logs on the flash, returns *default*.

 ```squirrel
 logger.eraseAll()
 assert(logger.last("Test Default value") == "Test Default value");
 logger.write("Now this is the oldest message on the flash")
 assert(logger.last(Test Default value") == "Now this is the oldest message on the flash");
 ```

### erase(*[address]*)

This method erases an object at SPIFlash address *address* by marking it erased. If *address* is not specified, it behaves as `eraseAll()` method with the default parameter.

### eraseAll(*[force]*)

Erases the entire allocated SPIFlash area. The optional *force* parameter is a Boolean value which defaults to `false`, a value which will cause the method to erase only the sectors written to by this library. You **must** pass in `true` if you wish to erase the entire allocated SPIFlash area.

### getPosition()

The *getPosition()* method returns the current SPI flash pointer, ie. where the SPIFlashLogger will perform the next read/write task. This information can be used along with the *setPosition()* method to optimize SPIFlash memory usage between deep sleeps.

See *setPosition()* for sample usage.

### setPosition(*position*)

The *setPosition()* method sets the current SPI flash pointer, ie. where the SPIFlashLogger will perform the next read/write task. Setting the pointer can help optimize SPI flash memory usage between deep sleeps, as it allows the SPIFlashLogger to be precise to one byte rather 256 bytes (the size of a chunk).

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

The SPIFlashLogger class is licensed under [MIT License](https://github.com/electricimp/spiflashlogger/tree/master/LICENSE).
