import ForceGraph3D from "react-force-graph-3d";
import { useCallback, useRef, useState, useEffect, useMemo } from "react";
import * as THREE from "three";
import SpriteText from "three-spritetext";
import { Button } from "@/components/ui/button";
import {
  ArrowLeft, ZoomIn, ZoomOut, Maximize, FileCode, Search,
  Eye, EyeOff, Settings2, Palette, Github, Star,
  ChevronRight, ChevronDown, Folder, FolderOpen,
  PanelLeftClose, PanelLeftOpen, Box
} from "lucide-react";
import { motion, AnimatePresence } from "framer-motion";

const DEFAULT_NODE_COLORS: Record<string, string> = {
  Repository: '#ffffff',
  Folder: '#f59e0b',
  File: '#42a5f5',
  Class: '#66bb6a',
  Interface: '#26a69a',
  Trait: '#81c784',
  Function: '#ffca28',
  Module: '#ef5350',
  Variable: '#ffa726',
  Enum: '#7e57c2',
  Struct: '#5c6bc0',
  Annotation: '#ec407a',
  Parameter: '#90a4ae',
  Other: '#78909c'
};

const DEFAULT_EDGE_COLORS: Record<string, string> = {
  CONTAINS: '#ffffff',
  CALLS: '#ab47bc',
  IMPORTS: '#42a5f5',
  INHERITS: '#66bb6a',
  HAS_PARAMETER: '#ffca28'
};

// ─── Tree Building ────────────────────────────────────────────────────────────
interface TreeNode {
  name: string;
  path: string;
  isDir: boolean;
  children: TreeNode[];
}

function buildTree(files: string[]): TreeNode[] {
  const root: TreeNode[] = [];

  for (const filePath of files) {
    const parts = filePath.split('/').filter(Boolean);
    let current = root;

    for (let i = 0; i < parts.length; i++) {
        const part = parts[i];
        const isLast = i === parts.length - 1;
        const nodePath = isLast ? filePath : parts.slice(0, i + 1).join('/');

        let node = current.find(n => n.name === part);
        if (!node) {
            node = { name: part, path: nodePath, isDir: !isLast, children: [] };
            current.push(node);
        }
        current = node.children;
    }
  }

  const sortNodes = (nodes: TreeNode[]): TreeNode[] =>
    nodes
      .sort((a, b) => {
        if (a.isDir && !b.isDir) return -1;
        if (!a.isDir && b.isDir) return 1;
        return a.name.localeCompare(b.name);
      })
      .map(n => ({ ...n, children: sortNodes(n.children) }));

  return sortNodes(root);
}

// ─── Tree Item ────────────────────────────────────────────────────────────────
function TreeItem({
  node, depth, selectedFile, onFileClick, searchQuery,
}: {
  node: TreeNode; depth: number; selectedFile: string | null; onFileClick: (path: string | null) => void; searchQuery: string;
}) {
  const [open, setOpen] = useState(depth < 2);

  useEffect(() => {
    if (searchQuery) setOpen(true);
  }, [searchQuery]);

  const isMatch = node.name.toLowerCase().includes(searchQuery.toLowerCase());
  const hasMatchingDescendant = (n: TreeNode): boolean =>
    n.name.toLowerCase().includes(searchQuery.toLowerCase()) ||
    n.children.some(hasMatchingDescendant);

  if (searchQuery && !hasMatchingDescendant(node) && !isMatch) return null;

  const indent = depth * 12;

  if (node.isDir) {
    return (
      <div>
        <button
          onClick={() => setOpen(o => !o)}
          className="w-full flex items-center gap-1 py-[3px] px-2 rounded-lg text-gray-400 hover:text-white hover:bg-white/5 transition-colors group"
          style={{ paddingLeft: `${indent + 8}px` }}
        >
          {open ? <ChevronDown className="w-3 h-3 flex-shrink-0 text-gray-500" /> : <ChevronRight className="w-3 h-3 flex-shrink-0 text-gray-500" />}
          {open ? <FolderOpen className="w-3.5 h-3.5 flex-shrink-0 text-amber-400 ml-0.5" /> : <Folder className="w-3.5 h-3.5 flex-shrink-0 text-amber-400 ml-0.5" />}
          <span className="text-[13px] text-gray-300 group-hover:text-white truncate font-medium ml-1">{node.name}</span>
        </button>
        {open && (
          <div>
            {node.children.map(child => (
              <TreeItem key={child.path} node={child} depth={depth + 1} selectedFile={selectedFile} onFileClick={onFileClick} searchQuery={searchQuery} />
            ))}
          </div>
        )}
      </div>
    );
  }

  const isSelected = selectedFile === node.path;
  const ext = node.name.split('.').pop() || '';
  const extColors: Record<string, string> = {
    py: '#ffca28', ts: '#42a5f5', tsx: '#42a5f5', js: '#f59e0b',
    jsx: '#f59e0b', rs: '#ef5350', go: '#26a69a', java: '#ef9a9a',
    c: '#90caf9', h: '#90caf9', cpp: '#7986cb', cs: '#b39ddb',
    rb: '#ef5350', php: '#9fa8da', swift: '#ffa726', kt: '#ab47bc',
    scala: '#e91e63', md: '#80cbc4', json: '#a5d6a7', yml: '#80deea',
    yaml: '#80deea', toml: '#ffcc02', sh: '#a5d6a7',
  };
  const dotColor = extColors[ext] || '#78909c';

  return (
    <button
      onClick={() => onFileClick(node.path)}
      className={`w-full flex items-center gap-2 py-[3px] px-2 rounded-lg text-[13px] transition-all group ${isSelected ? 'bg-blue-500/20 text-blue-200 border border-blue-500/20' : 'text-gray-400 hover:text-gray-200 hover:bg-white/5 border border-transparent'}`}
      style={{ paddingLeft: `${indent + 20}px` }}
    >
      <div className="w-1.5 h-1.5 rounded-full flex-shrink-0" style={{ backgroundColor: dotColor, boxShadow: isSelected ? `0 0 6px ${dotColor}` : 'none' }} />
      <span className="truncate font-medium">{node.name}</span>
    </button>
  );
}

// ─── Main Component ───────────────────────────────────────────────────────────
const MIN_SIDEBAR_W = 180;
const MAX_SIDEBAR_W = 520;
const DEFAULT_SIDEBAR_W = 300;

export default function CodeGraphViewer3D({ data, onClose, onToggleMode }: { data: any, onClose: () => void, onToggleMode: () => void }) {
  const fgRef = useRef<any>();
  const [dimensions, setDimensions] = useState({ width: window.innerWidth, height: window.innerHeight });
  const [hoverNode, setHoverNode] = useState<any>(null);
  const [searchQuery, setSearchQuery] = useState("");
  const [selectedFile, setSelectedFile] = useState<string | null>(null);
  const [focusSet, setFocusSet] = useState<{ nodes: Set<number>, links: Set<any> } | null>(null);

  const [nodeColors, setNodeColors] = useState(DEFAULT_NODE_COLORS);
  const [edgeColors, setEdgeColors] = useState(DEFAULT_EDGE_COLORS);
  const [visibleNodeTypes, setVisibleNodeTypes] = useState<Set<string>>(() => {
    const all = new Set(Object.keys(DEFAULT_NODE_COLORS));
    all.delete('Variable');
    all.delete('Parameter');
    return all;
  });
  const [showConfig, setShowConfig] = useState(false);

  const [sidebarWidth, setSidebarWidth] = useState(DEFAULT_SIDEBAR_W);
  const [collapsed, setCollapsed] = useState(false);
  const isResizing = useRef(false);
  const resizeStartX = useRef(0);
  const resizeStartW = useRef(DEFAULT_SIDEBAR_W);

  useEffect(() => {
    const handleResize = () => setDimensions({ width: window.innerWidth, height: window.innerHeight });
    window.addEventListener('resize', handleResize);
    return () => window.removeEventListener('resize', handleResize);
  }, []);

  const onDragStart = (e: React.MouseEvent) => {
    e.preventDefault();
    isResizing.current = true;
    resizeStartX.current = e.clientX;
    resizeStartW.current = sidebarWidth;

    const onMove = (ev: MouseEvent) => {
      if (!isResizing.current) return;
      const delta = ev.clientX - resizeStartX.current;
      setSidebarWidth(Math.min(MAX_SIDEBAR_W, Math.max(MIN_SIDEBAR_W, resizeStartW.current + delta)));
    };
    const onUp = () => {
      isResizing.current = false;
      window.removeEventListener('mousemove', onMove);
      window.removeEventListener('mouseup', onUp);
    };
    window.addEventListener('mousemove', onMove);
    window.addEventListener('mouseup', onUp);
  };

  const filteredData = useMemo(() => {
    const visibleNodes = data.nodes.filter((n: any) => visibleNodeTypes.has(n.type));
    const nodeIds = new Set(visibleNodes.map((n: any) => n.id));
    const visibleLinks = data.links.filter((l: any) =>
      nodeIds.has(typeof l.source === 'object' ? l.source.id : l.source) &&
      nodeIds.has(typeof l.target === 'object' ? l.target.id : l.target)
    );
    return { nodes: visibleNodes, links: visibleLinks };
  }, [data, visibleNodeTypes]);

  const toggleNodeType = (type: string) => {
    const next = new Set(visibleNodeTypes);
    if (next.has(type)) next.delete(type);
    else next.add(type);
    setVisibleNodeTypes(next);
  };

  const fileTree = useMemo(() => buildTree(data.files || []), [data.files]);

  const onFileClick = (path: string | null) => {
    if (!path) {
      setSelectedFile(null);
      setFocusSet(null);
      return;
    }

    setSelectedFile(path);
    const fileNode = data.nodes.find((n: any) => n.file === path && n.type === 'File');
    if (fileNode) {
      const distance = 150;
      const distRatio = 1 + distance/Math.hypot(fileNode.x, fileNode.y, fileNode.z);

      if (fgRef.current) {
        fgRef.current.cameraPosition(
          { x: fileNode.x * distRatio, y: fileNode.y * distRatio, z: fileNode.z * distRatio }, // new position
          fileNode, // lookAt ({ x, y, z })
          2000  // ms transition duration
        );
      }

      const nodesInFocus = new Set<number>();
      const linksInFocus = new Set<any>();
      nodesInFocus.add(fileNode.id);

      data.links.forEach((l: any) => {
        const sId = typeof l.source === 'object' ? l.source.id : l.source;
        const tId = typeof l.target === 'object' ? l.target.id : l.target;
        if (sId === fileNode.id || tId === fileNode.id) {
          nodesInFocus.add(sId);
          nodesInFocus.add(tId);
          linksInFocus.add(l);
        }
      });

      setFocusSet({ nodes: nodesInFocus, links: linksInFocus });
    }
  };

  const getLinkColor = useCallback((link: any) => {
    const isFocused = focusSet ? focusSet.links.has(link) : true;
    const baseColor = edgeColors[link.type] || 'rgba(255,255,255,0.4)';
    if (!isFocused) return 'rgba(255, 255, 255, 0.05)';
    return baseColor;
  }, [focusSet, edgeColors]);

  const nodeThreeObject = useCallback((node: any) => {
    const isHovered = hoverNode && node.id === hoverNode.id;
    const isFocused = focusSet ? focusSet.nodes.has(node.id) : true;
    const baseColor = nodeColors[node.type] || nodeColors.Other;
    
    // Create City Building Group
    const group = new THREE.Group();
    
    // The visual block
    const isFile = node.type === 'File' || node.type === 'Folder';
    const buildingHeight = isFile ? ((node.val || 1) * 3) : ((node.val || 1) * 1);
    const boxSize = isFile ? 4 : 2;
    
    const opacity = isFocused ? (isHovered ? 1.0 : 0.9) : 0.15;
    
    const material = new THREE.MeshLambertMaterial({
        color: baseColor,
        transparent: true,
        opacity: opacity,
        emissive: isHovered ? baseColor : 0x000000,
        emissiveIntensity: isHovered ? 0.6 : 0
    });
    
    let geometry;
    if (isFile) {
       geometry = new THREE.BoxGeometry(boxSize, boxSize, buildingHeight);
    } else {
       geometry = new THREE.CylinderGeometry(boxSize, boxSize, buildingHeight, 16);
    }
    
    const mesh = new THREE.Mesh(geometry, material);
    
    // Important: we need the building to stand tall, not lay sideways.
    // In ForceGraph3d z is usually up/down or depth. We'll rotate the geometry if we want 'buildings'
    // but default sphere coords might be uniform. 
    group.add(mesh);
    
    // Add text sprite
    if (isHovered || isFocused) {
        const sprite = new SpriteText(node.name || 'Unknown');
        sprite.color = 'white';
        sprite.textHeight = isHovered ? 4 : 2;
        sprite.position.z = (buildingHeight / 2) + 2; 
        sprite.position.y = 2; // Offset slightly
        if (!isFocused) sprite.color = 'rgba(255,255,255,0.3)';
        group.add(sprite);
    }
    
    return group;
  }, [hoverNode, focusSet, nodeColors]);

  const effectiveSidebarW = collapsed ? 0 : sidebarWidth;

  return (
    <motion.div initial={{ opacity: 0 }} animate={{ opacity: 1 }} exit={{ opacity: 0 }} className="fixed inset-0 z-50 bg-[#020202] overflow-hidden flex font-sans">
      <div className="relative h-full flex-shrink-0 flex" style={{ width: collapsed ? 0 : sidebarWidth, transition: isResizing.current ? 'none' : 'width 0.2s ease' }}>
        <AnimatePresence>
          {!collapsed && (
            <motion.div key="sidebar" initial={{ opacity: 0, x: -20 }} animate={{ opacity: 1, x: 0 }} exit={{ opacity: 0, x: -20 }} transition={{ duration: 0.18 }} className="flex flex-col h-full w-full bg-[#0d0d0d] border-r border-white/[0.07] z-[70] shadow-2xl overflow-hidden">
              <div className="px-4 pt-4 pb-2 flex-shrink-0">
                <Button onClick={onClose} variant="ghost" className="w-full justify-start text-gray-400 hover:text-white hover:bg-white/5 mb-4 rounded-xl border border-white/5 transition-colors text-sm">
                  <ArrowLeft className="w-4 h-4 mr-2" /> Back to Dashboard
                </Button>
                <div className="flex items-center justify-between mb-3">
                  <h2 className="text-sm font-bold text-white flex items-center gap-2 tracking-tight uppercase">
                    <FileCode className="w-4 h-4 text-blue-400" /> Project Tree (3D)
                  </h2>
                  <div className="flex items-center gap-1">
                    <button onClick={onToggleMode} className="p-1.5 rounded-lg text-blue-400 hover:text-blue-300 hover:bg-white/5 bg-blue-500/10 transition-colors" title="Switch to 2D Mode">
                      <Box className="w-4 h-4" />
                    </button>
                    <button onClick={() => setShowConfig(!showConfig)} title="Graph Settings" className={`p-1.5 rounded-lg transition-colors ${showConfig ? 'bg-blue-500/20 text-blue-400' : 'text-gray-500 hover:text-white hover:bg-white/5'}`}>
                      <Settings2 className="w-4 h-4" />
                    </button>
                    <button onClick={() => setCollapsed(true)} title="Collapse sidebar" className="p-1.5 rounded-lg text-gray-500 hover:text-white hover:bg-white/5 transition-colors">
                      <PanelLeftClose className="w-4 h-4" />
                    </button>
                  </div>
                </div>
                <div className="relative mb-2">
                  <Search className="absolute left-3 top-1/2 -translate-y-1/2 w-3.5 h-3.5 text-gray-500" />
                  <input type="text" placeholder="Filter files..." value={searchQuery} onChange={(e) => setSearchQuery(e.target.value)} className="w-full bg-white/5 border border-white/8 rounded-lg py-1.5 pl-9 pr-3 text-[13px] text-white placeholder:text-gray-600 focus:outline-none focus:ring-1 focus:ring-blue-500/50 transition-all" />
                </div>
              </div>
              <div className="flex-1 overflow-y-auto px-2 py-1 custom-scrollbar">
                {showConfig ? (
                  <motion.div initial={{ opacity: 0, x: -10 }} animate={{ opacity: 1, x: 0 }} className="p-3 space-y-6">
                    <div>
                      <h3 className="text-[10px] font-bold text-gray-500 uppercase tracking-widest mb-4 flex items-center gap-2"><Palette className="w-3 h-3" /> Visualization Config</h3>
                      <div className="space-y-3">
                        {Object.keys(DEFAULT_NODE_COLORS).map(type => (
                          <div key={type} className="flex items-center justify-between group">
                            <div className="flex items-center gap-3">
                              <button onClick={() => toggleNodeType(type)} className={`p-1 rounded transition-colors ${visibleNodeTypes.has(type) ? 'text-blue-400 bg-blue-500/10' : 'text-gray-600'}`}>
                                {visibleNodeTypes.has(type) ? <Eye className="w-4 h-4" /> : <EyeOff className="w-4 h-4" />}
                              </button>
                              <span className={`text-sm ${visibleNodeTypes.has(type) ? 'text-gray-200' : 'text-gray-600'}`}>{type}</span>
                            </div>
                            <input type="color" value={nodeColors[type] || '#78909c'} onChange={(e) => setNodeColors({ ...nodeColors, [type]: e.target.value })} className="w-6 h-6 bg-transparent border-none cursor-pointer p-0 rounded overflow-hidden" />
                          </div>
                        ))}
                      </div>
                    </div>
                  </motion.div>
                ) : (
                  <div className="py-1">
                    {fileTree.map(node => (
                      <TreeItem key={node.path} node={node} depth={0} selectedFile={selectedFile} onFileClick={onFileClick} searchQuery={searchQuery} />
                    ))}
                  </div>
                )}
              </div>
            </motion.div>
          )}
        </AnimatePresence>
        {!collapsed && <div onMouseDown={onDragStart} className="absolute right-0 top-0 h-full w-1 cursor-col-resize z-[80] group flex items-center justify-center"><div className="w-0.5 h-full bg-white/5 group-hover:bg-blue-500/50 transition-colors duration-150" /></div>}
      </div>

      {collapsed && <button onClick={() => setCollapsed(false)} className="absolute left-0 top-1/2 -translate-y-1/2 z-[80] bg-[#0d0d0d] border border-white/10 hover:border-blue-500/40 hover:bg-white/5 text-gray-400 hover:text-white transition-all rounded-r-xl p-2 shadow-2xl"><PanelLeftOpen className="w-4 h-4" /></button>}

      <div className="flex-1 relative bg-[radial-gradient(circle_at_center,_#0a0a0a_0%,_#000_100%)] overflow-hidden">
        
        <div className="absolute top-6 left-6 z-[60] flex flex-col gap-4">
          <AnimatePresence>
            {selectedFile && (
              <motion.button initial={{ opacity: 0, scale: 0.9 }} animate={{ opacity: 1, scale: 1 }} exit={{ opacity: 0, scale: 0.9 }} onClick={() => onFileClick(null)} className="bg-red-500/20 hover:bg-red-500/40 text-red-400 border border-red-500/30 text-xs font-bold uppercase tracking-widest py-3 px-5 rounded-xl backdrop-blur-xl transition-all shadow-xl">
                Clear Focus
              </motion.button>
            )}
          </AnimatePresence>
        </div>

        <ForceGraph3D
          ref={fgRef}
          graphData={filteredData}
          width={dimensions.width - effectiveSidebarW}
          height={dimensions.height}
          nodeLabel={(node: any) => node.name}
          linkColor={getLinkColor}
          linkWidth={(link: any) => focusSet && focusSet.links.has(link) ? 2 : 0.5}
          linkDirectionalParticles={(l: any) => focusSet ? (focusSet.links.has(l) ? 4 : 0) : (filteredData.links.length > 500 ? 0 : 2)}
          linkDirectionalParticleWidth={2}
          linkCurvature={0.25}
          nodeThreeObject={nodeThreeObject}
          onNodeClick={(node: any) => {
            if (node.type === 'File') onFileClick(node.file);
          }}
          onBackgroundClick={() => onFileClick(null)}
          onNodeHover={setHoverNode}
          d3VelocityDecay={0.3}
        />
      </div>
    </motion.div>
  );
}
