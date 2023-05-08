pragma solidity =0.5.16;

import './interfaces/IUniswapV2ERC20.sol';
import './libraries/SafeMath.sol';

// 流动性代币合约，也称为LP Token合约，但代币实际名称为Uniswap V2，简称UNI-V2
// 用户往资金池注入流动性的一种凭证，也称为【流动性代币】，本质上和Compound的cToken类似。
// 当用户往某个币对的配对合约里转入两种币，即添加流动性，就可以得到配对合约返回的LP Token，享受手续费分成收益。
// 每个配对合约（UniswapV2Pair）都有对应的一种LP Token与之绑定。
// 其实，UniswapV2Pair继承了UniswapV2ERC20，所以配对合约本身也是LP Token合约。
contract UniswapV2ERC20 is IUniswapV2ERC20 {
    using SafeMath for uint;

    string public constant name = 'Uniswap V2';
    string public constant symbol = 'UNI-V2';
    uint8 public constant decimals = 18;
    uint  public totalSupply;
    mapping(address => uint) public balanceOf;
    mapping(address => mapping(address => uint)) public allowance;

    bytes32 public DOMAIN_SEPARATOR;
    // keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)");
    bytes32 public constant PERMIT_TYPEHASH = 0x6e71edae12b1b97f4d1f60370fef10105fa2faae0126114a169c64845d6126c9;
    mapping(address => uint) public nonces;

    event Approval(address indexed owner, address indexed spender, uint value);
    event Transfer(address indexed from, address indexed to, uint value);

    constructor() public {
        uint chainId;
        assembly {
            chainId := chainid
        }
        DOMAIN_SEPARATOR = keccak256(
            abi.encode(
                keccak256('EIP712Domain(string name,string version,uint256 chainId,address verifyingContract)'),
                keccak256(bytes(name)),
                keccak256(bytes('1')),
                chainId,
                address(this)
            )
        );
    }

    function _mint(address to, uint value) internal {
        totalSupply = totalSupply.add(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(address(0), to, value);
    }

    function _burn(address from, uint value) internal {
        balanceOf[from] = balanceOf[from].sub(value);
        totalSupply = totalSupply.sub(value);
        emit Transfer(from, address(0), value);
    }

    function _approve(address owner, address spender, uint value) private {
        allowance[owner][spender] = value;
        emit Approval(owner, spender, value);
    }

    function _transfer(address from, address to, uint value) private {
        balanceOf[from] = balanceOf[from].sub(value);
        balanceOf[to] = balanceOf[to].add(value);
        emit Transfer(from, to, value);
    }

    function approve(address spender, uint value) external returns (bool) {
        _approve(msg.sender, spender, value);
        return true;
    }

    function transfer(address to, uint value) external returns (bool) {
        _transfer(msg.sender, to, value);
        return true;
    }

    function transferFrom(address from, address to, uint value) external returns (bool) {
        if (allowance[from][msg.sender] != uint(-1)) {
            allowance[from][msg.sender] = allowance[from][msg.sender].sub(value);
        }
        _transfer(from, to, value);
        return true;
    }

    // 允许用户在链下签署授权的交易，生成任何人都可以使用并提交给区块链的签名
    // permit功能与approve类似，但是permit允许第三方代为执行，如A需要向B授权，但是A没有ETH付gas，A可以用自己的私钥签名，让C来执行permit
    function permit(address owner, address spender, uint value, uint deadline, uint8 v, bytes32 r, bytes32 s) external {
        require(deadline >= block.timestamp, 'UniswapV2: EXPIRED');
        // 将授权的信息如owner、sender、value、nonce、deadline等信息打包后进行hash
        // 为了避免重放攻击，hash过程中还附加了其他信息，如DOMAIN_SEPARATOR、DOMAIN_SEPARATOR，其中DOMAIN_SEPARATOR的值等于keccak256("Permit(address owner,address spender,uint256 value,uint256 nonce,uint256 deadline)")
        // 这两个变量被添加到签名信息中，目的是让这个签名只能用于本条链的本合约的本功能（Permit）使用，从而避免这个签名被拿到其他合约或其他链的合约实施重放攻击。
        bytes32 digest = keccak256(
            abi.encodePacked(
                '\x19\x01',
                DOMAIN_SEPARATOR,
                keccak256(abi.encode(PERMIT_TYPEHASH, owner, spender, value, nonces[owner]++, deadline))
            )
        );
        // 使用ecrecover(hash,v,r,s)计算签名者的公钥
        address recoveredAddress = ecrecover(digest, v, r, s);
        // 如果签名者就是owner才同意授权
        require(recoveredAddress != address(0) && recoveredAddress == owner, 'UniswapV2: INVALID_SIGNATURE');
        // 授权
        _approve(owner, spender, value);
    }
}
