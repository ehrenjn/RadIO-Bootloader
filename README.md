An ATmega328p / ATmega328pb bootloader for @danielj-n's [RadIO project](https://github.com/danielj-n/RadIO/)





## Dependencies
- **python 3.6** or later
- **pyserial**  
install with pip via `pip install pyserial`



## Set Up

1. flash *RadIO Bootloader.hex* to RadIO
2. install dependencies listed above
3. compile the program you want to upload to RadIO
	- must be compiled to **binary** (not hex)  
	to compile to binary using gcc run the following commands:
		- `avr-gcc -Wall -g -Os -mmcu=atmega328p -o output.o input.c` (compiles input.c to output.o)
		- `avr-objcopy -O binary output.o output.bin` (converts output.o into a raw binary, output.bin)
	- compiled code must target either ATmega328p or ATmega328pb
4. prepare RadIO for a serial upload
	- connect RadIO and computer using a USB cable
	- flip the bootloader enable switch on
	- reset RadIO
	- ensure that RadIO's bootloader indicator LED is on



## Usage

`python upload.py <file> <port>`

**file** - the name of the compiled binary file to upload to radIO  
**port** - (optional in Windows) the serial port that radIO is plugged in to

if the program is uploaded successfully the bootloader indicator LED will turn off and the uploaded program will begin