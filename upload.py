#IF VERIFICATION HANGS BUT THE BOOTLOADED PROGRAM EXECUTES ANYWAY ITS ALMOST CERTAINLY THE HORRIBLE GLITCH IN PYSERIAL (race condition)

import serial
import sys
import os
import time

BAUD_RATE = 38400
BYTES_PER_CHUNK = 15 * 128 #bootloader accepts 15 pages of data at a time
CHECKSUM_LENGTH = 2 #checksum is 2 bytes long
MAX_BOOTLOAD_RESPONSE_TIME = 1 #seconds until a timeout occurs when reading



def error(msg):
    print(f"ERROR: {msg}")
    exit()


def invalid_write():
    error("the bootloader attempted to write to a memory location occupied by itself (are you uploading a program > 32256 bytes?)")

def do_nothing():
    pass

BYTE_ACTIONS = {
    b'w': do_nothing, #next word request
    b'd': do_nothing, #done receiving data
    b'o': invalid_write #invalid write error
}



ERROR_BYTE_MAX = bytes([31])
ERROR_BYTE_MIN = bytes([1])

def is_usart_error_byte(byte):
    return byte >= ERROR_BYTE_MIN and byte <= ERROR_BYTE_MAX

def bit_n(byte, n):
    return (byte & (1 << n)) != 0

def parse_usart_error(error_byte):
    error_byte = error_byte[0] #convert to int
    if bit_n(error_byte, 3): #data overrun
        print("ERROR: USART Data OverRun: the bootloader received a new byte while the USART buffer was already full")
    if bit_n(error_byte, 4): #frame error
        print("ERROR: USART Frame Error: the bootloader received one or more invalid start/stop bits")
    exit()



LOAD_BAR_LENGTH = 30
RESTART_LINE = "\x1b[F"

def print_stats(byte_num, total_bytes):
    num_blocks = round(byte_num/total_bytes * LOAD_BAR_LENGTH)
    loading_bar = "#"*num_blocks + " "*(LOAD_BAR_LENGTH - num_blocks) 
    print(f"{RESTART_LINE}[{loading_bar}] {byte_num}/{total_bytes} bytes uploaded")



def chunk_data(data):
    return [
        data[chunk_start: chunk_start + BYTES_PER_CHUNK]
        for chunk_start in range(0, len(data), BYTES_PER_CHUNK)
    ]


class RadIOSerialPort(serial.Serial):
    
    def __init__(self, port_name):
        try:
            super().__init__(
                port_name,
                BAUD_RATE,
                parity = serial.PARITY_SPACE, #USING PARITY AS 9TH BIT (PARITY_SPACE means 0)
                stopbits = serial.STOPBITS_TWO,
                timeout = MAX_BOOTLOAD_RESPONSE_TIME
            )
        except serial.SerialException:
            error(f"port not found: {port_name}")

    def read(self, num_bytes=1):
        received = super().read(num_bytes)
        if len(received) < num_bytes: #if a timeout occured
            self.close()
            error("bootloader didn't respond")
        return received

    def write(self, data):
        try:
            super().write(data)
        except serial.serialutil.SerialTimeoutException:
            self.close()
            error("can't send data (was the serial cable disconnected?)")


def get_windows_ports():
    all_ports = (f"COM{port_num}" for port_num in range(256))
    real_ports = []
    for port_name in all_ports:
        try:
            port = serial.Serial(port_name)
            port.close()
            real_ports.append(port_name)
        except serial.SerialException: 
            pass
    return real_ports


def get_port(port_arg):
    if port_arg is not None: #use specified port if it exists
        return RadIOSerialPort(port_arg)

    possible_ports = get_windows_ports() if os_is_windows() else []
    if len(possible_ports) == 0:
        error("no serial port specified and no available ports found")
    elif len(possible_ports) == 1: #if theres only one possible port then use that one
        return RadIOSerialPort(possible_ports[0])

    else: #let user choose port if there is > 1 possible port
        for port_num, port in enumerate(possible_ports):
            print(f"{port_num}: {port}")
        chosen_port = input("port number to use: ")
        try:
            port_name = possible_ports[int(chosen_port)]
        except (ValueError, IndexError):
            error(f"invalid port number: {chosen_port}")
        return RadIOSerialPort(port_name)


def upload_chunk(port, chunk, is_last_chunk):
    if is_last_chunk: 
        port.write(chunk[:-1])
        time.sleep(0.06) #HAVE TO WAIT A BIT FOR PREVIOUS WRITE TO FINISH BEFORE CHANGING THE PARITY AGAIN (TERRIBLE RACE CONDITION OR SOMETHING IN PYSERIAL (probably windows specific and could have to do with ftdi specifically though)) (if I change to mark parity right after writing a byte then it'll use mark parity for that byte instead of space parity)
        port.parity = serial.PARITY_MARK #change 9th bit to a 1
        port.write(chunk[-1:])
    else:
        port.write(chunk)
    return port.read(1)


def process_bootloader_response(response):
    if is_usart_error_byte(response):
        parse_usart_error(response)
    elif response in BYTE_ACTIONS:
        BYTE_ACTIONS[response]()
    else:
        error(f"received weird byte from bootloader: {response}")


def os_is_windows():
    return sys.platform.startswith('win')

def windows_start_ansi():
    if os_is_windows(): #HAVE TO CLS BEFORE DOING ANY ANSI CONTROL STUFF IN WINDOWS FOR SOME UNGODLY REASON
        os.system('cls')

    
def BSD_checksum(data):
    checksum = len(data) #checksum is initialized to length of data
    for d in data:
        checksum = (checksum >> 1) + ((checksum & 1) << 15) #circular rotate right
        checksum += d
        checksum %= 2**16 #keep checksum 16 bit
    return checksum


def upload(port, data):
    windows_start_ansi()
    total_bytes_uploaded = 0
    data_chunks = chunk_data(data)
    print("uploading...\n")
    for chunk_num, chunk in enumerate(data_chunks):
        is_last_chunk = chunk_num == len(data_chunks) - 1
        response = upload_chunk(port, chunk, is_last_chunk)
        total_bytes_uploaded += len(chunk)
        print_stats(total_bytes_uploaded, len(data))
        process_bootloader_response(response)
    print("done uploading")


def verify(port, data):
    print("verifying upload...")
    data = data[-1::-1] #reverse data since bootloader sends it back in reverse order
    checksum = port.read(CHECKSUM_LENGTH)
    checksum = int.from_bytes(checksum, byteorder="big")
    if checksum != BSD_checksum(data):
        error("program wasn't uploaded properly (verification failed)")
    port.write(bytes(1)) #send one last byte to bootloader to let it know it can exit (can be any byte)
    print("done verifying")


def read_data_file(file_path):
    try:
        with open(file_path, 'rb') as data:
            return data.read()
    except FileNotFoundError:
        error(f"can't read provided file ({file_path})")


def parse_args(args):
    if len(args) >= 2:
        data_file = args[1]
        port_name = args[2] if len(args) > 2 else None
        return data_file, port_name
    else:
        error("please provide a program file to upload")



def bootload(args):
    data_file, port_name = parse_args(args)
    port = get_port(port_name)
    data = read_data_file(data_file)
    upload(port, data)
    verify(port, data)
    port.close()


if __name__ == "__main__":
    bootload(sys.argv)