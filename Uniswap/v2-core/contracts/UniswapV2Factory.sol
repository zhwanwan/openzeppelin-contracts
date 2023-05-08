pragma solidity =0.5.16;

import './interfaces/IUniswapV2Factory.sol';
import './UniswapV2Pair.sol';

//工厂合约用来部署配对合约，通过工厂合约的createPair()函数创建新的配对合约实例。
contract UniswapV2Factory is IUniswapV2Factory {
    address public feeTo; //收税地址
    address public feeToSetter; //收税权限控制地址

    //配对映射，地址=>（地址=>地址）即token0=>(token1=>pair)
    mapping(address => mapping(address => address)) public getPair;
    //所有配对数组
    address[] public allPairs;
    //事件：配对被创建
    event PairCreated(address indexed token0, address indexed token1, address pair, uint);

    constructor(address _feeToSetter) public {
        feeToSetter = _feeToSetter; //收税开关权限控制
    }

    //查询配对数组长度方法
    function allPairsLength() external view returns (uint) {
        return allPairs.length;
    }

    //工厂合约最核心的函数
    function createPair(address tokenA, address tokenB) external returns (address pair) {
        //确认tokenA不等于tokenB
        require(tokenA != tokenB, 'UniswapV2: IDENTICAL_ADDRESSES');
        //将tokenA和tokenB进行大小排序，确保tokenA小于tokenB
        (address token0, address token1) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        //确认token0不等于0地址
        require(token0 != address(0), 'UniswapV2: ZERO_ADDRESS');
        //确认配对映射中不存在token0=>token1
        require(getPair[token0][token1] == address(0), 'UniswapV2: PAIR_EXISTS'); // single check is sufficient
        // 获取UniswapV2Pair合约代码的创建字节码creationCode，其实还有运行时字节码runtimeCode，这里没用到
        // 这个创建字节码其实会在periphery项目中的UniswapV2Library库中用到，是被硬编码设置的值。
        bytes memory bytecode = type(UniswapV2Pair).creationCode;
        // 根据两个代币地址计算出一个盐值，对于任意币对，计算的盐值也是固定的，所以可以线下计算出该币对的盐值
        bytes32 salt = keccak256(abi.encodePacked(token0, token1));
        // assembly关键字包起一段内嵌汇编代码
        assembly {
        // 使用汇编创建合约：opcode
        // 为什么不用new而是使用create2操作码创建新合约：可以在部署合约前预先计算出合约的部署地址。
        // 因为UniswapV2Pair合约的创建字节码是固定的，币对的盐值也是固定的，所以最终计算出来的pair地址其实也是固定的。
            pair := create2(0, add(bytecode, 32), mload(bytecode), salt)
        }
        //调用pair地址的合约初始化方法
        IUniswapV2Pair(pair).initialize(token0, token1);
        getPair[token0][token1] = pair;
        getPair[token1][token0] = pair; // populate mapping in the reverse direction
        allPairs.push(pair);
        emit PairCreated(token0, token1, pair, allPairs.length);
    }

    function setFeeTo(address _feeTo) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeTo = _feeTo;
    }

    function setFeeToSetter(address _feeToSetter) external {
        require(msg.sender == feeToSetter, 'UniswapV2: FORBIDDEN');
        feeToSetter = _feeToSetter;
    }
}
